# build: image toolchain (env.build + docker-compose.build.yml)
# up:    production stack (.env only, no local build)
.PHONY: build push up down logs

build:
	./scripts/build.sh

push:
	./scripts/push.sh

up:
	./manage.sh up

down:
	./manage.sh down

logs:
	./manage.sh logs
