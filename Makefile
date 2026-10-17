.PHONY: setup up down logs ps test lint deploy backup restore demo-crash demo-backup clean

setup:            ## create .env from the example (does not overwrite)
	@test -f .env || (cp .env.example .env && echo "created .env, edit the passwords")

up: setup         ## build and start everything, wait until healthy
	docker compose up -d --build --wait

down:             ## stop everything (data volumes are kept)
	docker compose down

ps:
	docker compose ps

logs:             ## follow logs of all services
	docker compose logs -f --tail=50

test:             ## unit tests
	cd app && pip install -q -r requirements.txt -r requirements-dev.txt && python -m pytest -q

lint:
	cd app && ruff check .

deploy:           ## rolling update: make deploy TAG=v2
	./scripts/deploy.sh $(TAG)

backup:           ## take a backup now
	docker compose exec -T backup /bin/sh /scripts/backup.sh once

restore:          ## restore the newest backup (or: make restore FILE=backups/db-x.dump)
	./scripts/restore.sh $(FILE)

demo-crash:
	./scripts/demo-crash.sh

demo-backup:
	./scripts/demo-backup-restore.sh

clean:            ## DANGER: stop everything and delete all data volumes
	docker compose down -v
