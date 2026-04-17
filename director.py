#!/usr/bin/env python3
"""
Laptop director for multi-iPhone recording control.

Features:
- WebSocket control server for iPhone camera clients
- Tkinter GUI with connected device dashboard
- Broadcast controls: arm, prepare/start at future timestamp, stop at future timestamp
- Tentacle Sync E BLE timecode monitoring on the laptop
- Simple JSON protocol with request IDs and ACK tracking

Requires:
    pip install websockets bleak

Protocol (client -> director):
    {"type":"hello","device_id":"cam-01","name":"A-Cam-01","app_version":"1.0.0"}
    {"type":"status","device_id":"cam-01","recording":false,"battery":0.84,"storage_gb":128.5,
     "tentacle_state":"connected","timecode":"12:34:56:12","fps":30}
    {"type":"ack","device_id":"cam-01","request_id":"...","ok":true,"detail":"armed"}
    {"type":"pong","device_id":"cam-01","request_id":"..."}

Protocol (director -> client):
    {"type":"command","command":"arm","request_id":"..."}
    {"type":"command","command":"prepare_start","request_id":"...",
     "session_id":"...","start_at_unix_ms":1730000000000}
    {"type":"command","command":"commit_start","request_id":"...",
     "session_id":"...","start_at_unix_ms":1730000000000}
    {"type":"command","command":"prepare_stop","request_id":"...",
     "session_id":"...","stop_at_unix_ms":1730000000000}
    {"type":"command","command":"ping","request_id":"..."}
"""

from __future__ import annotations

import asyncio
import json
import queue
import threading
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime
from tkinter import END, LEFT, RIGHT, TOP, BOTH, X, Y, Tk, Text, StringVar, ttk
from typing import Any

try:
    import websockets
    from websockets.server import WebSocketServerProtocol
except Exception as exc:  # pragma: no cover - runtime guard
    raise SystemExit(
        "Missing dependency: websockets\n"
        "Install with: pip install websockets\n"
        f"Import error: {exc}"
    )

try:
    from bleak import BleakClient, BleakScanner
except Exception as exc:  # pragma: no cover - runtime guard
    BleakClient = None
    BleakScanner = None
    BLEAK_IMPORT_ERROR = exc
else:
    BLEAK_IMPORT_ERROR = None


TENTACLE_TIMECODE_CHAR_UUID = "0dab144c-2cb9-11e6-b67b-9e71128cae77"


@dataclass
class DeviceState:
    websocket: WebSocketServerProtocol
    device_id: str
    name: str
    app_version: str = ""
    last_seen_unix: float = field(default_factory=time.time)
    recording: bool = False
    armed: bool = False
    battery: float | None = None
    storage_gb: float | None = None
    tentacle_state: str = "unknown"
    timecode: str = ""
    fps: int | None = None
    pending_acks: dict[str, str] = field(default_factory=dict)

    @property
    def endpoint(self) -> str:
        addr = self.websocket.remote_address
        if not addr:
            return "?"
        if isinstance(addr, tuple) and len(addr) >= 2:
            return f"{addr[0]}:{addr[1]}"
        return str(addr)


def decode_tentacle_timecode(data: bytes) -> dict[str, Any] | None:
    if len(data) < 5:
        return None

    fps = int(data[0])
    hours = int(data[1])
    minutes = int(data[2])
    seconds = int(data[3])
    frames = int(data[4])
    if hours >= 24 or minutes >= 60 or seconds >= 60:
        return None

    return {
        "fps": fps,
        "hours": hours,
        "minutes": minutes,
        "seconds": seconds,
        "frames": frames,
        "timecode": f"{hours:02d}:{minutes:02d}:{seconds:02d}:{frames:02d}",
        "raw": data.hex(),
    }


class TentacleReader:
    def __init__(self, event_queue: queue.Queue[tuple[str, Any]]):
        self.event_queue = event_queue
        self._loop: asyncio.AbstractEventLoop | None = None
        self._loop_thread: threading.Thread | None = None
        self._running = False
        self._target_name = "NeuROK"
        self._client: BleakClient | None = None

    @property
    def is_running(self) -> bool:
        return self._running and self._loop is not None and self._loop.is_running()

    def start(self, target_name: str) -> None:
        if BleakScanner is None or BleakClient is None:
            self.log(
                "Tentacle monitoring unavailable: missing dependency 'bleak'. "
                f"Install with: pip install bleak (import error: {BLEAK_IMPORT_ERROR})"
            )
            return
        if self.is_running:
            self.log("Tentacle reader already running.")
            return

        self._target_name = target_name.strip() or "NeuROK"
        self._running = True
        self._loop_thread = threading.Thread(target=self._run_loop, daemon=True)
        self._loop_thread.start()
        self._emit_state(f"starting ({self._target_name})")

    def stop(self) -> None:
        self._running = False
        loop = self._loop
        if not loop:
            self._emit_state("stopped")
            return

        async def _shutdown() -> None:
            client = self._client
            if client is not None:
                try:
                    if client.is_connected:
                        await client.disconnect()
                except Exception:
                    pass

        fut = asyncio.run_coroutine_threadsafe(_shutdown(), loop)
        try:
            fut.result(timeout=5)
        except Exception:
            pass

        loop.call_soon_threadsafe(loop.stop)
        self._loop = None
        self._emit_state("stopped")

    def log(self, message: str) -> None:
        self.event_queue.put(("log", f"[{timestamp_now()}] {message}"))

    def _emit_state(self, state: str) -> None:
        self.event_queue.put(("tentacle_state", {"state": state}))

    def _emit_timecode(self, packet: dict[str, Any]) -> None:
        self.event_queue.put(("tentacle_timecode", packet))

    def _run_loop(self) -> None:
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        self._loop = loop

        main_task = loop.create_task(self._run_reader())
        try:
            loop.run_forever()
        finally:
            main_task.cancel()
            pending = asyncio.all_tasks(loop)
            for task in pending:
                task.cancel()
            if pending:
                loop.run_until_complete(asyncio.gather(*pending, return_exceptions=True))
            loop.close()

    async def _run_reader(self) -> None:
        while self._running:
            try:
                device = await self._find_device(self._target_name)
                if not device:
                    self._emit_state(f"not found ({self._target_name})")
                    await asyncio.sleep(1.0)
                    continue
                await self._connect_and_stream(device)
            except asyncio.CancelledError:
                break
            except Exception as exc:
                self.log(f"Tentacle reader error: {exc}")
                self._emit_state(f"error: {exc}")
                await asyncio.sleep(1.0)

    async def _find_device(self, target_name: str) -> Any | None:
        self._emit_state(f"scanning ({target_name})")
        devices = await BleakScanner.discover(timeout=6.0)
        target_folded = target_name.casefold()

        exact_match = None
        partial_match = None
        for device in devices:
            name = (device.name or "").strip()
            if not name:
                continue
            folded = name.casefold()
            if folded == target_folded:
                exact_match = device
                break
            if target_folded in folded and partial_match is None:
                partial_match = device
        return exact_match or partial_match

    async def _connect_and_stream(self, device: Any) -> None:
        device_name = (device.name or self._target_name).strip()
        self._emit_state(f"connecting ({device_name})")
        self.log(f"Tentacle connect: {device_name}")

        async with BleakClient(device) as client:
            self._client = client
            self._emit_state(f"connected ({device_name})")
            self.log(f"Tentacle connected: {device_name}")

            try:
                initial = await client.read_gatt_char(TENTACLE_TIMECODE_CHAR_UUID)
                decoded = decode_tentacle_timecode(bytes(initial))
                if decoded:
                    self._emit_timecode(decoded)
            except Exception as exc:
                self.log(f"Tentacle initial read failed: {exc}")

            def notification_handler(_: Any, data: Any) -> None:
                decoded = decode_tentacle_timecode(bytes(data))
                if decoded:
                    self._emit_timecode(decoded)

            await client.start_notify(TENTACLE_TIMECODE_CHAR_UUID, notification_handler)
            try:
                while self._running and client.is_connected:
                    await asyncio.sleep(0.5)
            finally:
                try:
                    await client.stop_notify(TENTACLE_TIMECODE_CHAR_UUID)
                except Exception:
                    pass
                self._client = None
                if self._running:
                    self._emit_state(f"reconnecting ({device_name})")


class DirectorServer:
    def __init__(self, event_queue: queue.Queue[tuple[str, Any]]):
        self.event_queue = event_queue
        self._server = None
        self._loop: asyncio.AbstractEventLoop | None = None
        self._loop_thread: threading.Thread | None = None
        self._host = "0.0.0.0"
        self._port = 8765
        self.devices: dict[WebSocketServerProtocol, DeviceState] = {}
        self._lock = threading.Lock()
        self._heartbeat_task: asyncio.Task | None = None

    @property
    def is_running(self) -> bool:
        return self._loop is not None and self._loop.is_running()

    def start(self, host: str, port: int) -> None:
        if self.is_running:
            self.log("Server already running.")
            return

        self._host = host
        self._port = port

        self._loop_thread = threading.Thread(target=self._run_loop, daemon=True)
        self._loop_thread.start()
        self.log(f"Starting server on ws://{host}:{port}")

    def stop(self) -> None:
        loop = self._loop
        if not loop:
            return

        async def _shutdown() -> None:
            self.log("Stopping server...")
            if self._heartbeat_task:
                self._heartbeat_task.cancel()
            if self._server is not None:
                self._server.close()
                await self._server.wait_closed()
            await self._disconnect_all()

        fut = asyncio.run_coroutine_threadsafe(_shutdown(), loop)
        try:
            fut.result(timeout=5)
        except Exception as exc:
            self.log(f"Shutdown warning: {exc}")

        loop.call_soon_threadsafe(loop.stop)
        self._loop = None
        self._server = None
        self.event_queue.put(("server_stopped", None))

    def send_command_all(self, command: str, payload: dict[str, Any] | None = None) -> None:
        payload = payload or {}
        loop = self._loop
        if not loop:
            self.log("Server not running.")
            return

        request_id = str(uuid.uuid4())
        msg = {
            "type": "command",
            "command": command,
            "request_id": request_id,
            **payload,
        }

        async def _broadcast() -> None:
            with self._lock:
                devices = list(self.devices.values())
            if not devices:
                self.log(f"No devices connected for command: {command}")
                return

            for device in devices:
                device.pending_acks[request_id] = command

            encoded = json.dumps(msg)
            results = await asyncio.gather(
                *(device.websocket.send(encoded) for device in devices),
                return_exceptions=True,
            )

            failures = 0
            for device, result in zip(devices, results):
                if isinstance(result, Exception):
                    failures += 1
                    self.log(f"Send failed to {device.name} ({device.device_id}): {result}")
            ok_count = len(devices) - failures
            self.log(
                f"Broadcast '{command}' request_id={request_id} sent to {ok_count}/{len(devices)} devices."
            )
            self.event_queue.put(("devices_updated", self.snapshot_devices()))

        asyncio.run_coroutine_threadsafe(_broadcast(), loop)

    def snapshot_devices(self) -> list[dict[str, Any]]:
        with self._lock:
            data = [
                {
                    "device_id": d.device_id,
                    "name": d.name,
                    "app_version": d.app_version,
                    "endpoint": d.endpoint,
                    "last_seen_unix": d.last_seen_unix,
                    "recording": d.recording,
                    "armed": d.armed,
                    "battery": d.battery,
                    "storage_gb": d.storage_gb,
                    "tentacle_state": d.tentacle_state,
                    "timecode": d.timecode,
                    "fps": d.fps,
                    "pending_acks": dict(d.pending_acks),
                }
                for d in self.devices.values()
            ]
        data.sort(key=lambda x: x["name"])
        return data

    def log(self, message: str) -> None:
        self.event_queue.put(("log", f"[{timestamp_now()}] {message}"))

    def _run_loop(self) -> None:
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        self._loop = loop

        async def _startup() -> None:
            self._server = await websockets.serve(self._handle_connection, self._host, self._port)
            self._heartbeat_task = asyncio.create_task(self._heartbeat_monitor())
            self.event_queue.put(("server_started", {"host": self._host, "port": self._port}))

        loop.run_until_complete(_startup())
        try:
            loop.run_forever()
        finally:
            pending = asyncio.all_tasks(loop)
            for task in pending:
                task.cancel()
            if pending:
                loop.run_until_complete(asyncio.gather(*pending, return_exceptions=True))
            loop.close()

    async def _disconnect_all(self) -> None:
        with self._lock:
            websockets_to_close = [d.websocket for d in self.devices.values()]
            self.devices.clear()
        for ws in websockets_to_close:
            try:
                await ws.close(code=1001, reason="Director shutdown")
            except Exception:
                pass
        self.event_queue.put(("devices_updated", self.snapshot_devices()))

    async def _heartbeat_monitor(self) -> None:
        while True:
            await asyncio.sleep(2.0)
            cutoff = time.time() - 10.0
            stale: list[WebSocketServerProtocol] = []
            with self._lock:
                for ws, d in self.devices.items():
                    if d.last_seen_unix < cutoff:
                        stale.append(ws)
            for ws in stale:
                try:
                    await ws.close(code=1001, reason="Heartbeat timeout")
                except Exception:
                    pass

    async def _handle_connection(self, websocket: WebSocketServerProtocol) -> None:
        provisional = DeviceState(
            websocket=websocket,
            device_id=f"unknown-{uuid.uuid4().hex[:8]}",
            name="Unknown",
        )
        with self._lock:
            self.devices[websocket] = provisional
        self.log(f"Client connected from {provisional.endpoint}")
        self.event_queue.put(("devices_updated", self.snapshot_devices()))

        try:
            async for raw in websocket:
                await self._handle_message(websocket, raw)
        except websockets.ConnectionClosed:
            pass
        except Exception as exc:
            self.log(f"Connection error: {exc}")
        finally:
            with self._lock:
                device = self.devices.pop(websocket, None)
            if device:
                self.log(f"Client disconnected: {device.name} ({device.device_id})")
            self.event_queue.put(("devices_updated", self.snapshot_devices()))

    async def _handle_message(self, websocket: WebSocketServerProtocol, raw: str) -> None:
        try:
            msg = json.loads(raw)
            if not isinstance(msg, dict):
                raise ValueError("Payload must be JSON object")
        except Exception as exc:
            self.log(f"Invalid JSON from client: {exc}")
            return

        mtype = msg.get("type")
        if not isinstance(mtype, str):
            self.log("Ignoring message with missing type.")
            return

        with self._lock:
            device = self.devices.get(websocket)
        if not device:
            return

        device.last_seen_unix = time.time()

        if mtype == "hello":
            device.device_id = str(msg.get("device_id") or device.device_id)
            device.name = str(msg.get("name") or device.name)
            device.app_version = str(msg.get("app_version") or "")
            self.log(f"HELLO from {device.name} ({device.device_id})")

        elif mtype == "status":
            device.recording = bool(msg.get("recording", device.recording))
            device.armed = bool(msg.get("armed", device.armed))
            device.battery = to_float_or_none(msg.get("battery"))
            device.storage_gb = to_float_or_none(msg.get("storage_gb"))
            if "tentacle_state" in msg:
                device.tentacle_state = str(msg.get("tentacle_state") or "unknown")
            if "timecode" in msg:
                device.timecode = str(msg.get("timecode") or "")
            fps = msg.get("fps")
            device.fps = int(fps) if isinstance(fps, int) else device.fps

        elif mtype == "ack":
            request_id = str(msg.get("request_id") or "")
            ok = bool(msg.get("ok", False))
            detail = str(msg.get("detail") or "")
            command = device.pending_acks.pop(request_id, "unknown")
            result = "OK" if ok else "FAIL"
            self.log(
                f"ACK {result} from {device.name} ({device.device_id}) command={command} req={request_id} detail={detail}"
            )

        elif mtype == "pong":
            request_id = str(msg.get("request_id") or "")
            device.pending_acks.pop(request_id, None)

        else:
            self.log(f"Unhandled message type '{mtype}' from {device.name}")

        self.event_queue.put(("devices_updated", self.snapshot_devices()))


class DirectorGUI:
    def __init__(self, root: Tk):
        self.root = root
        self.root.title("Multi-Cam Director")
        self.root.geometry("1250x700")

        self.event_queue: queue.Queue[tuple[str, Any]] = queue.Queue()
        self.server = DirectorServer(self.event_queue)
        self.tentacle_reader = TentacleReader(self.event_queue)

        self.host_var = StringVar(value="0.0.0.0")
        self.port_var = StringVar(value="8765")
        self.start_delay_var = StringVar(value="2.0")
        self.stop_delay_var = StringVar(value="2.0")
        self.tentacle_name_var = StringVar(value="NeuROK")
        self.tentacle_state_var = StringVar(value="Tentacle: idle")
        self.tentacle_timecode_var = StringVar(value="Director timecode: --:--:--:--")
        self._tentacle_anchor_monotonic: float | None = None
        self._tentacle_anchor_total_frames: int | None = None
        self._tentacle_anchor_fps: int | None = None

        self._build_ui()
        self._schedule_pump()
        self._schedule_status_refresh()
        self._schedule_tentacle_clock()

        self.root.protocol("WM_DELETE_WINDOW", self.on_close)

    def _build_ui(self) -> None:
        controls = ttk.Frame(self.root, padding=8)
        controls.pack(side=TOP, fill=X)

        ttk.Label(controls, text="Host:").pack(side=LEFT)
        ttk.Entry(controls, textvariable=self.host_var, width=15).pack(side=LEFT, padx=(4, 10))
        ttk.Label(controls, text="Port:").pack(side=LEFT)
        ttk.Entry(controls, textvariable=self.port_var, width=8).pack(side=LEFT, padx=(4, 10))

        ttk.Button(controls, text="Start Server", command=self.start_server).pack(side=LEFT, padx=3)
        ttk.Button(controls, text="Stop Server", command=self.stop_server).pack(side=LEFT, padx=3)
        ttk.Button(controls, text="Ping All", command=self.ping_all).pack(side=LEFT, padx=(10, 3))
        ttk.Label(controls, text="Tentacle Name:").pack(side=LEFT, padx=(16, 3))
        ttk.Entry(controls, textvariable=self.tentacle_name_var, width=12).pack(side=LEFT, padx=(2, 4))
        ttk.Button(controls, text="Connect TC", command=self.start_tentacle).pack(side=LEFT, padx=3)
        ttk.Button(controls, text="Stop TC", command=self.stop_tentacle).pack(side=LEFT, padx=3)

        ttk.Separator(self.root).pack(fill=X, padx=8, pady=6)

        actions = ttk.Frame(self.root, padding=(8, 2))
        actions.pack(side=TOP, fill=X)

        ttk.Button(actions, text="Arm All", command=self.arm_all).pack(side=LEFT, padx=3)
        ttk.Label(actions, text="Start Delay (s):").pack(side=LEFT, padx=(12, 3))
        ttk.Entry(actions, textvariable=self.start_delay_var, width=8).pack(side=LEFT)
        ttk.Button(actions, text="Prepare + Commit Start", command=self.start_all).pack(side=LEFT, padx=3)

        ttk.Label(actions, text="Stop Delay (s):").pack(side=LEFT, padx=(12, 3))
        ttk.Entry(actions, textvariable=self.stop_delay_var, width=8).pack(side=LEFT)
        ttk.Button(actions, text="Prepare Stop", command=self.stop_all).pack(side=LEFT, padx=3)

        columns = (
            "name",
            "device_id",
            "endpoint",
            "app",
            "armed",
            "recording",
            "battery",
            "storage",
            "tentacle",
            "timecode",
            "last_seen",
            "pending",
        )
        self.tree = ttk.Treeview(self.root, columns=columns, show="headings", height=18)
        for col in columns:
            self.tree.heading(col, text=col)

        widths = {
            "name": 120,
            "device_id": 130,
            "endpoint": 140,
            "app": 80,
            "armed": 65,
            "recording": 80,
            "battery": 70,
            "storage": 75,
            "tentacle": 110,
            "timecode": 120,
            "last_seen": 90,
            "pending": 210,
        }
        for col, width in widths.items():
            self.tree.column(col, width=width, anchor="center")

        self.tree.pack(fill=BOTH, expand=True, padx=8, pady=(6, 8))

        bottom = ttk.Frame(self.root, padding=8)
        bottom.pack(side=TOP, fill=BOTH, expand=True)

        self.status_label = ttk.Label(bottom, text="Server: stopped")
        self.status_label.pack(anchor="w", pady=(0, 6))
        self.tentacle_status_label = ttk.Label(bottom, textvariable=self.tentacle_state_var)
        self.tentacle_status_label.pack(anchor="w", pady=(0, 2))
        self.tentacle_timecode_label = ttk.Label(bottom, textvariable=self.tentacle_timecode_var)
        self.tentacle_timecode_label.pack(anchor="w", pady=(0, 6))

        self.log_box = Text(bottom, height=12, wrap="word")
        self.log_box.pack(side=LEFT, fill=BOTH, expand=True)

        log_scroll = ttk.Scrollbar(bottom, command=self.log_box.yview)
        log_scroll.pack(side=RIGHT, fill=Y)
        self.log_box.configure(yscrollcommand=log_scroll.set)

    def _schedule_pump(self) -> None:
        self._pump_events()
        self.root.after(100, self._schedule_pump)

    def _pump_events(self) -> None:
        while True:
            try:
                etype, payload = self.event_queue.get_nowait()
            except queue.Empty:
                break

            if etype == "log":
                self._append_log(str(payload))
            elif etype == "server_started":
                self.status_label.configure(text=f"Server: running on ws://{payload['host']}:{payload['port']}")
            elif etype == "server_stopped":
                self.status_label.configure(text="Server: stopped")
            elif etype == "devices_updated":
                self._refresh_tree(payload)
            elif etype == "tentacle_state":
                state = str(payload.get("state", "unknown")) if isinstance(payload, dict) else "unknown"
                self.tentacle_state_var.set(f"Tentacle: {state}")
            elif etype == "tentacle_timecode":
                if isinstance(payload, dict):
                    self._set_tentacle_anchor_from_packet(payload)

    def _schedule_status_refresh(self) -> None:
        self._refresh_tree(self.server.snapshot_devices())
        self.root.after(1000, self._schedule_status_refresh)

    def _schedule_tentacle_clock(self) -> None:
        self._tick_tentacle_clock()
        self.root.after(50, self._schedule_tentacle_clock)

    def _set_tentacle_anchor_from_packet(self, packet: dict[str, Any]) -> None:
        fps = packet.get("fps")
        hours = packet.get("hours")
        minutes = packet.get("minutes")
        seconds = packet.get("seconds")
        frames = packet.get("frames")
        if not all(isinstance(v, int) for v in (fps, hours, minutes, seconds, frames)):
            tc = str(packet.get("timecode") or "")
            self.tentacle_timecode_var.set(f"Director timecode: {timecode_text(tc, None)}")
            return
        if fps <= 0:
            return

        total_frames = ((((hours * 60) + minutes) * 60) + seconds) * fps + frames
        self._tentacle_anchor_monotonic = time.monotonic()
        self._tentacle_anchor_total_frames = total_frames
        self._tentacle_anchor_fps = fps
        self._tick_tentacle_clock()

    def _tick_tentacle_clock(self) -> None:
        if (
            self._tentacle_anchor_monotonic is None
            or self._tentacle_anchor_total_frames is None
            or self._tentacle_anchor_fps is None
            or self._tentacle_anchor_fps <= 0
        ):
            return

        fps = self._tentacle_anchor_fps
        elapsed = max(0.0, time.monotonic() - self._tentacle_anchor_monotonic)
        advanced_frames = int(elapsed * fps)
        total_frames = self._tentacle_anchor_total_frames + advanced_frames
        tc = timecode_from_total_frames(total_frames, fps)
        self.tentacle_timecode_var.set(f"Director timecode: {tc} @ {fps} fps")

    def _refresh_tree(self, devices: list[dict[str, Any]]) -> None:
        self.tree.delete(*self.tree.get_children())
        now = time.time()
        for d in devices:
            pending = ", ".join(d["pending_acks"].values()) if d["pending_acks"] else ""
            battery = f"{d['battery']*100:.0f}%" if isinstance(d["battery"], float) else "-"
            storage = f"{d['storage_gb']:.1f} GB" if isinstance(d["storage_gb"], float) else "-"
            age = max(0.0, now - float(d["last_seen_unix"]))
            last_seen = f"{age:.1f}s"

            self.tree.insert(
                "",
                END,
                values=(
                    d["name"],
                    d["device_id"],
                    d["endpoint"],
                    d["app_version"],
                    yes_no(d["armed"]),
                    yes_no(d["recording"]),
                    battery,
                    storage,
                    d["tentacle_state"],
                    timecode_text(d["timecode"], d["fps"]),
                    last_seen,
                    pending,
                ),
            )

    def _append_log(self, line: str) -> None:
        self.log_box.insert(END, line + "\n")
        self.log_box.see(END)

    def start_server(self) -> None:
        host = self.host_var.get().strip() or "0.0.0.0"
        try:
            port = int(self.port_var.get().strip())
        except ValueError:
            self._append_log(f"[{timestamp_now()}] Invalid port.")
            return
        self.server.start(host, port)

    def stop_server(self) -> None:
        self.server.stop()

    def ping_all(self) -> None:
        self.server.send_command_all("ping", {})

    def start_tentacle(self) -> None:
        target_name = self.tentacle_name_var.get().strip() or "NeuROK"
        self.tentacle_reader.start(target_name)

    def stop_tentacle(self) -> None:
        self.tentacle_reader.stop()

    def arm_all(self) -> None:
        self.server.send_command_all("arm", {})

    def start_all(self) -> None:
        delay = parse_delay(self.start_delay_var.get(), fallback=2.0)
        start_at_ms = int((time.time() + delay) * 1000)
        session_id = datetime.utcnow().strftime("session-%Y%m%d-%H%M%S")
        payload = {"session_id": session_id, "start_at_unix_ms": start_at_ms}

        # Two-step for safer coordination.
        self.server.send_command_all("prepare_start", payload)
        self.server.send_command_all("commit_start", payload)

    def stop_all(self) -> None:
        delay = parse_delay(self.stop_delay_var.get(), fallback=2.0)
        stop_at_ms = int((time.time() + delay) * 1000)
        session_id = datetime.utcnow().strftime("session-%Y%m%d-%H%M%S")
        payload = {"session_id": session_id, "stop_at_unix_ms": stop_at_ms}
        self.server.send_command_all("prepare_stop", payload)

    def on_close(self) -> None:
        self.tentacle_reader.stop()
        self.server.stop()
        self.root.destroy()


def parse_delay(value: str, fallback: float) -> float:
    try:
        parsed = float(value)
        return max(0.1, parsed)
    except Exception:
        return fallback


def yes_no(flag: bool) -> str:
    return "yes" if flag else "no"


def timestamp_now() -> str:
    return datetime.now().strftime("%H:%M:%S")


def to_float_or_none(value: Any) -> float | None:
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    return None


def timecode_text(tc: str, fps: int | None) -> str:
    if not tc:
        return ""
    if fps is None:
        return tc
    return f"{tc} @ {fps}"


def timecode_from_total_frames(total_frames: int, fps: int) -> str:
    if fps <= 0:
        return "--:--:--:--"
    frames_per_day = 24 * 60 * 60 * fps
    safe_total = total_frames % frames_per_day

    hours = safe_total // (60 * 60 * fps)
    remainder = safe_total % (60 * 60 * fps)
    minutes = remainder // (60 * fps)
    remainder = remainder % (60 * fps)
    seconds = remainder // fps
    frames = remainder % fps
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}:{frames:02d}"


def main() -> None:
    root = Tk()
    style = ttk.Style(root)
    try:
        style.theme_use("clam")
    except Exception:
        pass
    DirectorGUI(root)
    root.mainloop()


if __name__ == "__main__":
    main()
