# One-word commands so you don't memorise long docker lines.
.PHONY: up down logs ps smoke test lint build clean psql reset

up:        ## build and start the whole stack
	docker compose up -d --build
	@echo "-> http://localhost:$${WEB_PORT:-8080}"

down:      ## stop the stack (keeps the database data)
	docker compose down

reset:     ## stop the stack AND delete the database data
	docker compose down -v

logs:      ## follow logs from all three tiers
	docker compose logs -f

ps:        ## show container status and health
	docker compose ps

smoke:     ## run the integration test against the running stack
	./scripts/smoke.sh

test:      ## run the api unit tests locally
	cd api && python3 -m venv .venv && ./.venv/bin/pip install -q -r requirements-dev.txt && ./.venv/bin/pytest -v

lint:      ## lint the api code
	cd api && ./.venv/bin/ruff check .

psql:      ## open a database shell (the only way in — no public port)
	docker compose exec db psql -U postgres -d tasks

clean:     ## remove everything including volumes and local venvs
	docker compose down -v --remove-orphans
	rm -rf api/.venv api/.pytest_cache api/.ruff_cache api/__pycache__ api/tests/__pycache__
