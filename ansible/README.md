## RouterOS Ansible

This directory contains the new Ansible automation for the MikroTik router.

- Transport: RouterOS API (`community.routeros` collection), not SSH CLI scraping.
- Layout: one playbook (`playbooks/routeros.yml`) importing domain task files from `tasks/`.
- Goal: idempotent convergence using `community.routeros.api_modify` for managed paths.

### Quick start

1. Install dependencies:
   - `ansible-galaxy collection install -r ansible/requirements.yml`
   - `python -m pip install librouteros hvac`
2. Configure secret references in `ansible/vars/routeros-secrets.yml`.
3. Store required fields in OpenBao under configured KV path.
4. Export token (`OPENBAO_TOKEN` or `VAULT_TOKEN`).
5. Run:
   - `ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook ansible/playbooks/routeros.yml`

More details and design rationale: `docs/ansible/routeros-design.md`.
