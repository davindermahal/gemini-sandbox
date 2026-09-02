.PHONY: up down composer unit-test test-unit shell sandbox-image gemini

up: # Build and start the project's PHP container.
	UID=$$(id -u) GID=$$(id -g) docker compose up -d --build

down: # Stop and remove the project's containers.
	docker compose down

composer: # Run composer inside the container. Usage: make composer ARGS="require symfony/console"
	docker compose exec php composer $(ARGS)

unit-test: # Run the PHPUnit test suite inside the container.
	docker compose exec php php bin/phpunit

test-unit: unit-test # Alias for unit-test.

shell: # Open a shell inside the project's PHP container.
	docker compose exec php bash

sandbox-image: # Build the custom Gemini CLI sandbox image (Docker CLI + compose + Node 24 + DooD).
	docker build \
		--build-arg DOCKER_GID=$$(getent group docker | cut -d: -f3) \
		-t gemini-sandbox-demo:latest \
		-f .gemini/sandbox.Dockerfile .

gemini: # Run gemini via the sandboxed wrapper. Usage: make gemini ARGS="-s -p 'hello'"
	./bin/gemini-sandbox $(ARGS)
