#!/usr/bin/env python

import argparse
import os
import pathlib
from typing import Any, cast

import hvac
from hvac.api.auth_methods import Kubernetes
import yaml

# Read vault/policies dir then write what is there and delete missing
def synchronize_policies(client: hvac.Client):
    policies: dict[str, str] = {}
    # Read all policies files
    policy_dir = os.path.join(os.path.dirname(__file__), '../vault/policy')
    for filename in os.listdir(policy_dir):
        with open(os.path.join(policy_dir, filename), 'r') as f:
            policy_name = os.path.splitext(filename)[0]
            policies[policy_name] = f.read()
    
    policies_on_vault: list[str] = cast(list[str], client.sys.list_policies()['data']['policies'])

    # Delete policies that should not be there
    for policy in policies_on_vault:
        if policy not in policies and policy != 'root':
            print(f'Deleting policy: {policy}')
            client.sys.delete_policy(policy)
    
    # Update policies from local directory
    for policy_name, policy_content in policies.items():
        print(f'Updating policy: {policy_name}')
        client.sys.create_or_update_acl_policy(policy_name, policy_content)

# Read vault/kubernetes-config.yaml and write it to kubernetes auth method config
def synchronize_auth_kubernetes_config(client: hvac.Client):
    config_file = os.path.join(os.path.dirname(__file__), '../vault/kubernetes-config.yaml')
    with open(config_file, 'r') as f:
        config = cast(dict[str, str], yaml.safe_load(f.read()))
        _ = client.write_data('/auth/kubernetes/config', data=config)

# Read vault/kubernetes-roles dir then write what is there and delete missing 
def synchronize_kubernetes_roles(client: hvac.Client):
    kubernetes = Kubernetes(client.adapter)

    policy_dir = os.path.join(os.path.dirname(__file__), '../vault/kubernetes-auth-roles/')

    roles: dict[str, Any] = {} # pyright:ignore[reportExplicitAny]
    for filename in os.listdir(policy_dir):
        with open(os.path.join(policy_dir, filename), 'r') as f:
            role_name = os.path.splitext(filename)[0]
            roles[role_name] = yaml.safe_load(f.read())
    
    roles_on_vault: list[str] = []
    try:
        roles_on_vault = cast(list[str], kubernetes.list_roles()['keys'])
    except hvac.exceptions.InvalidPath: # pyright:ignore[reportAttributeAccessIssue, reportUnknownMemberType]
        print("No roles found on server!")

    
    for role in roles_on_vault:
        if role not in roles:
            print(f'Deleting role: {role}')
            kubernetes.delete_role(role)
    
    for role_name, role_content in roles.items(): # pyright:ignore[reportAny]
        print(f'Updating role: {role_name}')
        # Using write data instead of kubernetes.create_role, we can pass raw yaml
        _ = client.write_data(f'/auth/kubernetes/role/{role_name}', data=role_content) # pyright:ignore[reportAny]

def synchronize_approle_auth(client: hvac.Client):
    if client.sys.list_auth_methods().get('approle/') is None:
        print('Enabling AppRole auth method')
        client.sys.enable_auth_method('approle', 'AppRole authorization for CI')

    roles_dir = pathlib.Path(__file__).parent.joinpath('../vault/approles/')
    roles: dict[str, Any] = {}

    for filename in roles_dir.iterdir():
        with filename.open('r') as f:
            role = yaml.safe_load(f.read())
            assert type(role) is dict
            roles[filename.stem] = role

    roles_on_vault: list[str] = []
    roles_response = client.list("auth/approle/roles")
    if roles_response is not None:
        roles_on_vault = roles_response['data']['keys']

    for role in roles_on_vault:
        if role not in roles:
            print(f'Deleting role: {role}')
            client.delete(f'auth/approle/role/{role}')

    for role_name, role_content in roles.items():
        print(f'Updating role: {role_name}')
        client.write_data(f'auth/approle/role/{role_name}', data=role_content)

def synchronize_kubernetes_secretengine(client: hvac.Client):
    # Ensure kubernetes secret engine is enabled
    if client.sys.list_mounted_secrets_engines().get('kubernetes/') is None:
        print('Enabling kubernetes secret engine')
        client.sys.enable_secrets_engine('kubernetes', 'kubernetes', 'Cluster access')

    # Write empty config (all defaults, working on the same cluster)
    client.write('kubernetes/config', None)

    policy_dir = pathlib.Path(__file__).parent.joinpath('../vault/kubernetes-se-roles/')
    roles: dict[str, Any] = {}

    for filename in policy_dir.iterdir():
        with filename.open('r') as f:
            role = yaml.safe_load(f.read())
            assert type(role) is dict
            # generated_role_rules must be json or yaml formatted string, convert it
            if 'generated_role_rules' in role and type(role['generated_role_rules']) is not str:
                role['generated_role_rules'] = yaml.safe_dump(role['generated_role_rules'])
            roles[filename.stem] = role

    roles_on_vault: list[str] = []
    roles_response = client.list("kubernetes/roles")
    if roles_response is not None:
        roles_on_vault = roles_response['data']['keys']

    for role in roles_on_vault:
        if role not in roles:
            print(f'Deleting role: {role}')
            client.delete(f'kubernetes/roles/{role}')

    for role_name, role_content in roles.items():
        print(f'Updating role: {role_name}')
        client.write_data(f'kubernetes/roles/{role_name}', data=role_content)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(
        prog="synchronizeVault",
        description="Update vault config"
    )
    args = parser.parse_args()

    client = hvac.Client(url=os.environ['VAULT_ADDR'])

    print('Synchronizing policies')
    synchronize_policies(client)

    print('Synchronizing kubernetes config')
    synchronize_auth_kubernetes_config(client)

    print('Synchronizing kubernetes auth roles')
    synchronize_kubernetes_roles(client)

    print('Synchronizing AppRole auth method')
    synchronize_approle_auth(client)

    print('Synchronizing kubernetes secret engine')
    synchronize_kubernetes_secretengine(client)
