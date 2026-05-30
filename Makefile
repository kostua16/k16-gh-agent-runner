# build: image toolchain (env.build + docker-compose.build.yml)
# up:    production stack (.env only, no local build)
.PHONY: build push up down logs

build:
	./scripts/build.sh

push:
	./scripts/push.sh

up:
	./scripts/up.sh

down:
	./scripts/down.sh

logs:
	./scripts/logs.sh
