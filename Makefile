# One-word commands so you don't memorise long docker lines.
.PHONY: up down logs ps smoke chaos test lint build clean psql reset urls

up:        ## build and start the whole stack
	docker compose up -d --build
	@$(MAKE) --no-print-directory urls

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

chaos:     ## break the database on purpose and prove the alert fires
	./scripts/chaos.sh

urls:      ## print every UI this stack exposes
	@echo "  app         http://localhost:$${WEB_PORT:-8080}"
	@echo "  prometheus  http://localhost:$${PROMETHEUS_PORT:-9090}"
	@echo "  targets     http://localhost:$${PROMETHEUS_PORT:-9090}/targets"
	@echo "  alerts      http://localhost:$${PROMETHEUS_PORT:-9090}/alerts"
	@echo "  grafana     http://localhost:$${GRAFANA_PORT:-3000}  (admin/admin)"

test:      ## run the api unit tests locally
	cd api && python3 -m venv .venv && ./.venv/bin/pip install -q -r requirements-dev.txt && ./.venv/bin/pytest -v

lint:      ## lint the api code
	cd api && ./.venv/bin/ruff check .

psql:      ## open a database shell (the only way in — no public port)
	docker compose exec db psql -U postgres -d tasks

clean:     ## remove everything including volumes and local venvs
	docker compose down -v --remove-orphans
	rm -rf api/.venv api/.pytest_cache api/.ruff_cache api/__pycache__ api/tests/__pycache__
