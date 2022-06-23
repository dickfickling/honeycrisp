import asyncio
from aiohttp import web
import pyatv

routes = web.RouteTableDef()


@routes.get('/')
async def scan(request):
    return web.Response(text="Hello world!")


@routes.get('/scan')
async def scan(request):
    devices = []
    for result in await pyatv.scan(loop=asyncio.get_event_loop()):
        devices.append({"name": result.name, "address": str(
            result.address), "id": result.identifier})
    return web.json_response(devices)


def add_credentials(config, query):
    for service in config.services:
        proto_name = service.protocol.name.lower()  # E.g. Protocol.MRP -> "mrp"
        if proto_name in query:
            config.set_credentials(service.protocol, query[proto_name])


@routes.get('/connect/{id}')
async def connect(request):
    loop = asyncio.get_event_loop()
    device_id = request.match_info["id"]

    if device_id in request.app["atv"]:
        return web.Response(text=f"Already connected to {device_id}")

    results = await pyatv.scan(identifier=device_id, loop=loop)
    if not results:
        return web.Response(text="Device not found", status=500)

    add_credentials(results[0], request.query)

    try:
        atv = await pyatv.connect(results[0], loop=loop)
    except Exception as ex:
        return web.Response(text=f"Failed to connect to device: {ex}", status=500)

    request.app["atv"][device_id] = atv

    return web.Response(text=f"Connected to device {device_id}")


@routes.get("/volume/{id}/{command}")
async def volume(request):
    device_id = request.match_info["id"]
    atv = request.app["atv"][device_id]

    if not atv:
        return web.Response(text=f"Not connected to {device_id}", status=500)

    try:
        await getattr(atv.audio, request.match_info["command"])()
    except Exception as ex:
        return web.Response(text=f"Remote control command failed: {ex}")

    return web.Response(text="OK")


@routes.get("/remote_control/{id}/{command}")
async def remote_control(request):
    device_id = request.match_info["id"]
    atv = request.app["atv"][device_id]

    if not atv:
        return web.Response(text=f"Not connected to {device_id}", status=500)

    try:
        await getattr(atv.remote_control, request.match_info["command"])()
    except Exception as ex:
        return web.Response(text=f"Remote control command failed: {ex}")

    return web.Response(text="OK")


async def on_shutdown(app: web.Application) -> None:
    for atv in app["atv"].values():
        atv.close()


async def on_startup(app: web.Application) -> None:
    print("Python listening on 22000", flush=True)


def main():
    app = web.Application()
    app["atv"] = {}
    app.add_routes(routes)
    app.on_shutdown.append(on_shutdown)
    app.on_startup.append(on_startup)
    web.run_app(app, port=22000)


if __name__ == "__main__":
    main()
