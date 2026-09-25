# signal-infra

BOAZ Signal cloud infrastructure definitions and deployment configuration.

## Scope

- Cloud resources, networking, and environment configuration managed as code.
- Keep application code, database migrations, and Airflow DAGs in `signal-pipeline`.
- Add infrastructure modules and environment folders when the cloud design is approved.

## Secrets and state

- Never commit credentials, private keys, `.env` files, Terraform state, plans, or real `.tfvars` files.
- Use GitHub Actions secrets or the approved cloud secret manager for sensitive values.
- Commit `.tfvars.example` files with placeholder values only.
- Review every public change for secrets before merging.

## Ownership

Infrastructure changes require review by the infrastructure owner before deployment.
