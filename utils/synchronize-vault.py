#!/usr/bin/env python

import argparse
import os
from hvac.api.system_backend import mount
import yaml
import hvac
from hvac.api.auth_methods import Kubernetes, kubernetes

# Read vault/policies dir then write what is there and delete missing
def synchronize_policies(client: hvac.Client):
    policies = {}
    # Read all policies files
    policy_dir = os.path.join(os.path.dirname(__file__), '../vault/policy')
    for filename in os.listdir(policy_dir):
        with open(os.path.join(policy_dir, filename), 'r') as f:
            policy_name = os.path.splitext(filename)[0]
            policies[policy_name] = f.read()
    
    policies_on_vault = client.sys.list_policies()['data']['policies']

    # Delete policies that should not be there
    for policy in policies_on_vault:
        if policy not in policies and policy != 'root':
            print(f'Deleting policy: {policy}')
            client.sys.delete_policy(policy)
    
    # Update policies from local directory
    for policy_name, policy_content in policies.items():
        print(f'Updating policy: {policy_name}')
        client.sys.create_or_update_acl_policy(policy_name, policy_content)

# Read vault/kubernetes-roles dir then write what is there and delete missing 
def synchronize_kubernetes_roles(client: hvac.Client):
    kubernetes = Kubernetes(client.adapter)

    policy_dir = os.path.join(os.path.dirname(__file__), '../vault/kubernetes-roles/')

    roles = {}
    for filename in os.listdir(policy_dir):
        with open(os.path.join(policy_dir, filename), 'r') as f:
            role_name = os.path.splitext(filename)[0]
            roles[role_name] = yaml.safe_load(f.read())
    
    roles_on_vault = []
    try:
        roles_on_vault = kubernetes.list_roles()['keys']
    except hvac.exceptions.InvalidPath:
        print("No roles found on server!")

    
    for role in roles_on_vault:
        if role not in roles_on_vault:
            print(f'Deleting role: {role}')
            kubernetes.delete_role(role)
    
    for role_name, role_content in roles.items():
        print(f'Updating role: {role_name}')
        # Using write data instead of kubernetes.create_role, we can pass raw yaml
        client.write_data(f'/auth/kubernetes/role/{role_name}', data=role_content)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(
        prog="synchronizeVault",
        description="Update vault config"
    )
    args = parser.parse_args()

    client = hvac.Client(url=os.environ['VAULT_ADDR'])

    print('Synchronizing policies')
    synchronize_policies(client)

    print('Synchronizing kubernetes roles')
    synchronize_kubernetes_roles(client)
