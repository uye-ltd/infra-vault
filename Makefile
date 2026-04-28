.PHONY: up down build logs status init apply-policies

COMPOSE = docker compose -f docker/docker-compose.yml

up:
	$(COMPOSE) up -d

down:
	$(COMPOSE) down

build:
	$(COMPOSE) build --pull

logs:
	$(COMPOSE) logs -f vault

status:
	docker exec vault vault status -address=http://127.0.0.1:8200

init:
	VAULT_ADDR=http://127.0.0.1:8200 ./scripts/init-vault.sh

apply-policies:
	VAULT_ADDR=http://127.0.0.1:8200 ./scripts/apply-policies.sh
