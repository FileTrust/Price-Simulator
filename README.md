# FileTrust Price Simulator

A configurable simulation feed. It publishes one number — the configured
value of 1 FTU in USDC —
as a small DEX-style quote API, so every part of FileTrust that shows a
price in dollars reads the same figure from one place.

Today its only consumer is the Explorer, which asks for it server-side and
passes it to the page. Nothing else in the network needs it to run: a
missing price is a missing figure, never a broken service.

## Install

```bash
git clone https://github.com/FileTrust/Price-Simulator.git
cd Price-Simulator
./install.sh
```

Python 3.10 or newer is required. Nothing is compiled and nothing is downloaded: the server is one file of
standard Python, so `install.sh` only creates your `config.json`, checks
the service answers, and tells you how to start it.

By default it installs a systemd service, because this runs on a machine
nobody is watching: a crash, an out-of-memory kill, a power cut or a
reboot all end with the service running again, without anyone noticing it
had stopped.

```bash
./install.sh --user             # install the service for this user, no root
./install.sh --no-service       # set up only; you start it yourself
./install.sh --price 0.035      # publish a different price
./install.sh --port 9000        # serve somewhere else
./install.sh --help             # every option
```

Afterwards:

```bash
systemctl status filetrust-ftuprice       # --user if installed for a user
journalctl -u filetrust-ftuprice -f
```

Or start it by hand, with no service at all:

```bash
python3 server.py
```

## Dependencies

None. Everything it uses is in Python's standard library, so there is no
virtual environment and nothing to download; `requirements.txt` is there
and empty on purpose.

### Behind a reverse proxy

Leave `host` at `127.0.0.1` and let the proxy reach it there; set `public_url`
to the name the proxy answers on. Nothing but a person reads `public_url` --
what the Explorer uses is whatever the network config service publishes.

## Settings

`config.json` is yours and is never overwritten by an update; the
repository ships `config.default.json`, and `install.sh` adds any new
setting to your copy without touching what you have set.

The price lives in one place:

```json
"price": { "ftu_usdc": "0.02" }
```

Change it and the next request serves the new value — the file is read per
request, so nothing has to be restarted.

`host` defaults to `127.0.0.1`, which only this machine can reach. That is
deliberate: the Explorer proxies the price through its own address, so this
service never needs to be exposed. Set `0.0.0.0` only if something on
another machine must call it directly, and put something in front of it
that decides who may.

## What it answers

```
GET /health                     is it alive
GET /v1/quote?amount=1          the quote, DEX-shaped
GET /v1/pairs                   every pair it knows (FTU/USDC)
```

The quote carries `price`, `inversePrice`, `amountIn`, `amountOut` and the
token details, so a real DEX or an adapter can replace this later without
anything that reads it having to change.

## Connecting the Explorer

Set the public price URL in the Network Config service's `ftu_price_url`
setting. Explorer consumes it server-side. Publish a DNS service URL behind
TLS; do not commit an origin server address or private reverse-proxy settings.

## Configuration example and limitations

`config.default.json` is the safe, versioned example; the installer copies it
to your ignored `config.json`. Its chain ID matches the current FileTrust
example network (31338). Token and DEX addresses are zero placeholders, and
`0.02` is an illustrative price. Set these values for your own deployment.

This service does not discover a market price, connect to a DEX, or provide a
verified financial oracle. Quotes reflect the configured value. Do not use it
as a production pricing oracle without implementing and reviewing an actual
price source. It needs no database, account, signing key or API credential.

The API exposes defined token fields only and refuses response data containing
IP literals, credentials or local machine paths. Configuration errors return a
generic response. Keep runtime logs and local settings private.

## License and security

FileTrust-owned code uses **FSL-1.1-ALv2**, matching FileTrust and Explorer.
This is Fair Source with an Apache-2.0 future grant, rather than immediate open
source. See [LICENSE](LICENSE), [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)
and [SECURITY.md](SECURITY.md).
