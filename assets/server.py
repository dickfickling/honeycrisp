import asyncio
from aiohttp import web
import pyatv

routes = web.RouteTableDef()


@routes.get('/')
async def alive(request):
    return web.json_response({"ok": "honeycrisp"})


@routes.get('/pair/{id}/begin')
async def beginPairing(request):
    loop = asyncio.get_event_loop()
    device_id = request.match_info["id"]
    results = await pyatv.scan(identifier=device_id, loop=loop)
    pairing = await pyatv.pair(results[0], protocol=pyatv.Protocol.AirPlay, loop=loop)
    request.app["pairings"][device_id] = pairing
    await pairing.begin()

    if pairing.device_provides_pin:
        return web.json_response({
            "device_provides_pin": True,
        })
    else:
        pairing.pin(1234)
        return web.json_response({
            "device_provides_pin": False,
            "pin_to_enter": 1234,
        })


@routes.get('/pair/{id}/finish')
async def finishPairing(request):
    loop = asyncio.get_event_loop()
    device_id = request.match_info["id"]
    if device_id not in request.app["pairings"]:
        return web.json_response({
            "has_paired": False,
            "error": "Pairing not started"
        })

    pairing = request.app["pairings"][device_id]

    if pairing.device_provides_pin:
        pin = request.query["pin"]
        pairing.pin(pin)

    await pairing.finish()
    await pairing.close()

    return web.json_response({
        "has_paired": pairing.has_paired,
        "credentials": pairing.service.credentials
    })


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

    results = await pyatv.scan(identifier=device_id, loop=loop)
    if not results:
        return web.json_response({"connected": False, "error": "device_not_found"})

    add_credentials(results[0], request.query)

    try:
        atv = await pyatv.connect(results[0], loop=loop)
    except Exception as ex:
        return web.json_response({"connected": False, "error": getattr(ex, 'message', repr(ex))})

    request.app["atv"][device_id] = atv

    return web.json_response({"connected": True})


@routes.get("/remote_control/{id}/{command}")
async def remote_control(request):
    device_id = request.match_info["id"]
    atv = request.app["atv"][device_id]

    if not atv:
        return web.json_response({"success": False, "error": "not_connected"})

    try:
        await getattr(atv.remote_control, request.match_info["command"])()
    except pyatv.exceptions.BlockedStateError as ex:
        return web.json_response({"success": False, "error": "not_connected"})
    except Exception as ex:
        return web.json_response({"success": False, "error": getattr(ex, 'message', repr(ex))})

    return web.json_response({"success": True})


async def on_shutdown(app: web.Application) -> None:
    for atv in app["atv"].values():
        atv.close()


async def on_startup(app: web.Application) -> None:
    print("Python listening on 22000", flush=True)


def main():
    app = web.Application()
    app["atv"] = {}
    app["pairings"] = {}
    app.add_routes(routes)
    app.on_shutdown.append(on_shutdown)
    app.on_startup.append(on_startup)
    web.run_app(app, port=22000)


if __name__ == "__main__":
    main()
