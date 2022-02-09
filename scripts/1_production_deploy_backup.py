import time

from brownie import (
    accounts,
    network,
    MyStrategy,
    TheVault,
    AdminUpgradeabilityProxy,
    interface,
)

from _setup.config import (
    WANT, 
    REGISTRY,

    PERFORMANCE_FEE_GOVERNANCE,
    PERFORMANCE_FEE_STRATEGIST,
    WITHDRAWAL_FEE,
    MANAGEMENT_FEE,
)

from helpers.constants import AddressZero

import click
from rich.console import Console

console = Console()

sleep_between_tx = 1

# set a gas price
network.gas_price("600 gwei")

def main():
    """
    FOR STRATEGISTS AND GOVERNANCE
    Deploys a Controller, a TheVault and your strategy under upgradable proxies and wires them up.
    Note that it sets your deployer account as the governance for the three contracts so that
    the setup and production tests are simpler and more efficient. The rest of the permissioned actors
    are set based on the latest entries from the Badger Registry.
    """

    # Get deployer account from local keystore
    dev = connect_account()
    verify = False

    # Get actors from registry
    # registry = interface.IBadgerRegistry(REGISTRY)

    # strategist = registry.get("governance")
    # badgerTree = registry.get("badgerTree")
    # guardian = registry.get("guardian")
    # keeper = registry.get("keeper")
    # proxyAdmin = registry.get("proxyAdminTimelock")

    ## Override the registry actors since they are not deployed on Fantom
    strategist = dev.address
    badgerTree = dev.address
    guardian = dev.address
    keeper = dev.address
    proxyAdmin = "0x20Dce41Acca85E8222D6861Aa6D23B6C941777bF"

    name = "Fantom Curve TriCrypto Strategy"  #  In vaults 1.5 it's the full name
    symbol = "bcrvUSDBTCETH" # e.g The full symbol (remember to add symbol from want)

    assert strategist != AddressZero
    assert guardian != AddressZero
    assert keeper != AddressZero
    assert proxyAdmin != AddressZero
    assert name != "Name Prefix Here"
    assert symbol != "bveSymbolHere"

    # Deploy Vault
    vault = deploy_vault(
        dev.address,  # Deployer will be set as governance for testing stage
        keeper,
        guardian,
        dev.address,
        badgerTree,
        proxyAdmin,
        name,
        symbol,
        dev,
        verify
    )

    # Deploy Strategy
    strategy = deploy_strategy(
        vault,
        proxyAdmin,
        dev,
        verify
    )

    dev_setup = vault.setStrategy(strategy, {"from": dev})
    console.print("[green]Strategy was set was deployed at: [/green]", dev_setup)



def deploy_vault(governance, keeper, guardian, strategist, badgerTree, proxyAdmin, name, symbol, dev, verify):
    args = [
        WANT,
        governance,
        keeper,
        guardian,
        governance,
        strategist,
        badgerTree,
        name,
        symbol,
        [
            PERFORMANCE_FEE_GOVERNANCE,
            PERFORMANCE_FEE_STRATEGIST,
            WITHDRAWAL_FEE,
            MANAGEMENT_FEE,
        ],
    ]

    print("Vault Arguments: ", args)

    vault_logic = TheVault.deploy(
        {"from": dev},
        publish_source=verify
    )  # TheVault Logic ## TODO: Deploy and use that
    with open("vault.txt", "w") as f:
        # Writing data to a file
        f.write(TheVault.get_verification_info()['flattened_source'])

    vault_proxy = AdminUpgradeabilityProxy.deploy(
        vault_logic,
        proxyAdmin,
        vault_logic.initialize.encode_input(*args),
        {"from": dev},
        publish_source=verify
    )
    time.sleep(sleep_between_tx)
    with open("vaultProxy.txt", "w") as f:
        # Writing data to a file
        f.write(AdminUpgradeabilityProxy.get_verification_info()['flattened_source'])

    ## We delete from deploy and then fetch again so we can interact
    AdminUpgradeabilityProxy.remove(vault_proxy)
    vault_proxy = TheVault.at(vault_proxy.address)

    console.print("[green]Vault was deployed at: [/green]", vault_proxy.address)

    return vault_proxy


def deploy_strategy(
     vault, proxyAdmin, dev, verify
):

    args = [
        vault,
        [WANT]
    ]

    print("Strategy Arguments: ", args)

    strat_logic = MyStrategy.deploy({"from": dev}, publish_source=verify)
    with open("strategy.txt", "w") as f:
        # Writing data to a file
        f.write(MyStrategy.get_verification_info()['flattened_source'])

    time.sleep(sleep_between_tx)

    strat_proxy = AdminUpgradeabilityProxy.deploy(
        strat_logic,
        proxyAdmin,
        strat_logic.initialize.encode_input(*args),
        {"from": dev},
        publish_source=verify
    )
    time.sleep(sleep_between_tx)
    with open("strategyProxy.txt", "w") as f:
        # Writing data to a file
        f.write(AdminUpgradeabilityProxy.get_verification_info()['flattened_source'])


    ## We delete from deploy and then fetch again so we can interact
    AdminUpgradeabilityProxy.remove(strat_proxy)
    strat_proxy = MyStrategy.at(strat_proxy.address)

    console.print("[green]Strategy was deployed at: [/green]", strat_proxy.address)

    return strat_proxy



def connect_account():
    click.echo(f"You are using the '{network.show_active()}' network")
    dev = accounts.load(click.prompt("Account", type=click.Choice(accounts.load())))
    click.echo(f"You are using: 'dev' [{dev.address}]")
    return dev
