all: up

shell:
	@podman compose exec main bash

up:
	@podman compose up -d
	@podman compose run --rm main ''

down:
	@podman compose down

logs:
	@podman compose logs -f