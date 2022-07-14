# Ansible Role: Wireguard Cloud Gateway

[Consensus Enterprises](https://consensus.enterprises/)' [Ansible](https://en.wikipedia.org/wiki/Ansible_(software)) role for setting up [Wireguard](https://en.wikipedia.org/wiki/WireGuard) as a gateway [VPN](https://en.wikipedia.org/wiki/Virtual_private_network) server for [IaaS](https://en.wikipedia.org/wiki/Infrastructure_as_a_service)-based cloud networks.

For background information, please see our article [Protecting your cloud networks with WireGuard VPN and Ansible](https://consensus.enterprises/blog/protecting-cloud-networks-wireguard-ansible/).

## Overview

This role can be run in one of two modes, "server" or "client".  Server mode sets up Wireguard to act as a VPN server gateway to a cloud network, and client mode is for setting up clients that connect to it, allowing access to all of the network's internal VMs.

In either case, it does the following:

1. Temporarily adds a pre-defined [security group](https://docs.openstack.org/python-openstackclient/latest/cli/command-objects/security-group.html) for publicly [SSH](https://en.wikipedia.org/wiki/Secure_Shell)ing to the [VM](https://en.wikipedia.org/wiki/Virtual_machine), to allow for Wireguard installation (unless disabled or in client mode).
1. Installs Wireguard.
1. Generates the [private key](https://en.wikipedia.org/wiki/Public-key_cryptography).
1. Generates the Wireguard application configuration.
1. Generates the [public key](https://en.wikipedia.org/wiki/Public-key_cryptography).
1. Sets up Wireguard as a service & (re)starts it.
1. Removes the temporary security group (unless disabled or in client mode).

## Requirements

### Server mode

* A cloud infrastructure with an private network hosted at an IaaS provider.
* A powered-on VM for use as a VPN server / gateway to the other internal VMs.

If you'd also like to have this role alter your security groups, to temporarily allow SSH connections to your server, you also need the following:

* A security group for publicly SSHing to that VM.
* Cloud provider configuration data (endpoints & credentials) existing in [`clouds.yaml` or the environment](https://docs.openstack.org/python-openstackclient/latest/configuration/index.html).

If you want to disable this feature, be sure to have another means of controlling this outside of Ansible (e.g. a [Terraform](https://en.wikipedia.org/wiki/Terraform_(software)) [provisioner](https://www.terraform.io/docs/provisioners/index.html) or manually).  Disabling this because you allow public SSH connections to your VPN server is not recommended.

Ideally, you'd bring up your infrastructure with a security group applied to the server that allows VPN connections on some port and also blocks public SSH access (e.g. "vpn").  You'd then have another one which allows it, e.g. "public_ssh".  This would be the one applied here, temporarily, to install Wireguard on the server.

### Client mode

* A VM running one of the supported operating systems (OSes).

## Supported OSes and cloud providers

Merge requests or funding for other OSes and cloud providers (e.g. AWS, Azure, GCP, etc.) are welcome and appreciated.

### Operating Systems

* [Ubuntu](https://en.wikipedia.org/wiki/Ubuntu)-based OSes.  This role has been tested on Ubuntus 18.04 & 20.04 LTS.

### Cloud providers

* [OpenStack](https://en.wikipedia.org/wiki/OpenStack)

Please contribute to add support for other systems!

## Role Variables

See [defaults/main.yml](https://gitlab.com/consensus.enterprises/ansible-roles/ansible-role-wireguard-cloud-gateway/-/blob/master/roles/wireguard_cloud_gateway/defaults/main.yml) for all role variables.

## Dependencies

None.

## Example Playbook

### Initial server set-up

Run this first to get the server's public key for providing to client configurations.  There are two options here:

* Running from Terraform (e.g. on initial infrastructure deployment)
* Running the playbook independently (e.g. to add new keys later)

If running via Terraform, you'll want it to handle temporarily opening the firewall.  Otherwise, let the role handle it.  See below for details.

#### Running the playbook via Terraform

##### Provisioner configuration

```hcl
resource "null_resource" "provision_wireguard_on_gateway" {
  depends_on = [openstack_compute_floatingip_associate_v2.public_ip_gateway0]
  connection {
    type = "ssh"
    user = "ubuntu"
    agent = true
    host = openstack_networking_floatingip_v2.floating_ip_gateway0.address
  }

  # While the Ansible role below adds and removes the security group for
  # installation, we can't run it until we can connect to the VM via SSH and
  # ensure it's up *before* we run the role.  So we have to do it ourselves.
  provisioner "local-exec" {
    command = "openstack server add security group ${openstack_compute_instance_v2.gateway[0].name} public_ssh"
  }

  # Ensure the VM is up by connecting to it and running a command.
  provisioner "remote-exec" {
    inline = ["echo 'Confirming that the gateway VM is up & running.'"]
  }

  # Run the Ansible role to install the app.
  provisioner "local-exec" {
    command = "ANSIBLE_STDOUT_CALLBACK=debug ANSIBLE_FORCE_COLOR=True ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -vv --inventory ${openstack_networking_floatingip_v2.floating_ip_gateway0.address}, vpn-server.yml"
    working_dir = "../path/to/playbooks"
  }

  provisioner "local-exec" {
    command = "openstack server remove security group ${openstack_compute_instance_v2.gateway[0].name} public_ssh"
  }
}
```
##### Playbook configuration

```yml
---
- name: Configure the VPN
  hosts: all
  remote_user: ubuntu
  # Will be run later when the firewall is open.
  gather_facts: false
  roles:
    - role: consensus.wireguard-cloud-gateway
      setup_type: server
      # Handled by the Terraform provisioner.
      alter_security_groups: false
      # Wait until firewall is opened.
      gather_facts_later: true
      server_wireguard_ip: 192.168.66.1
      server_internal_interface: ens3
```

#### Running the playbook independently

You can run the same playbook as above, but make some alterations when running via the CLI (use the server IP address if you didn't just update your DNS record):

```sh
ANSIBLE_STDOUT_CALLBACK=debug ansible-playbook -vv --inventory vpn.example.com, --extra-vars="alter_security_groups=true" /path/to/vpn-server.yml
```

Because the role is now handling the firewall alterations, not Terraform, this has to be specified with variable settings.

### Client set-up

Now that the server's public key has been defined in the previous section, we can set up one or more clients.

```yaml
---
- hosts: localhost
  connection: local
  roles:
    - consensus.wireguard-cloud-gateway
  vars:
    setup_type: client
    # The private cloud network.  Can be a comma-separated list.
    client_accessible_ips: "10.0.0.0/24"
    server_public_ip: 203.123.113.123
    server_public_key: "2cISCNtFl9ZJUXhcwwLTBte76LiYQC3W8R8pL+hTVzM="
```

This can typically be run on the client from the CLI like so:

```sh
ANSIBLE_STDOUT_CALLBACK=debug ansible-playbook -vv --ask-become-pass --inventory localhost, --extra-vars="client_wireguard_ip=192.168.66.2" /path/to/vpn-client.yml
```

### Server reconfiguration with clients' public keys

Reconfigure the server to include public keys from the clients, now that they're available from the previous section.

Rerun the initial server set-up, the *Running the playbook independently* section, but add a `peers` section to the list of variables in the playbook first, which includes public keys for all of the clients as well as their Wireguard IP addresses.

```yml
    peers:
      # Alice's laptop
      - public_key: "5pILQAtFl9ZJUXhcwwLTBte76LiYQC3W8R8pL+hXTzA="
        allowed_ips: "192.168.66.2/32"
      # Bob's phone
      - public_key: "3jIPLAtFl9ZJUXhcwwLTBte76LiYQC3W8R8pL+hXSzZ="
        allowed_ips: "192.168.66.3/32"
```

## Testing

Tests can be run like so (with more or fewer "v"s for verbosity):

```sh
ANSIBLE_STDOUT_CALLBACK=debug ansible-playbook -vv --ask-become-pass --inventory TARGET_HOSTNAME, /path/to/this/role/tests/TEST_NAME.yml
```

Feel free to add your own tests in `tests/`, using existing ones as examples.  Contributions welcome.

## FAQ

### Unable to start service wg-quick@wg0

If your playbook fails with:

> Unable to start service wg-quick@wg0: Job for wg-quick@wg0.service failed because the control process exited with error code.
>
> See "systemctl status wg-quick@wg0.service" and "journalctl -xe" for details.

...and that reveals something like:

```
Jul 15 02:20:26 gateway0 systemd[1]: Starting WireGuard via wg-quick(8) for wg0...
Jul 15 02:20:26 gateway0 wg-quick[7777]: [#] ip link add wg0 type wireguard
Jul 15 02:20:26 gateway0 wg-quick[7777]: RTNETLINK answers: Operation not supported
Jul 15 02:20:26 gateway0 wg-quick[7777]: Unable to access interface: Protocol not supported
Jul 15 02:20:26 gateway0 wg-quick[7777]: [#] ip link delete dev wg0
Jul 15 02:20:26 gateway0 wg-quick[7777]: Cannot find device "wg0"
Jul 15 02:20:26 gateway0 systemd[1]: wg-quick@wg0.service: Main process exited, code=exited, status=1/FAI
Jul 15 02:20:26 gateway0 systemd[1]: wg-quick@wg0.service: Failed with result 'exit-code'.
Jul 15 02:20:26 gateway0 systemd[1]: Failed to start WireGuard via wg-quick(8) for wg0.
```

This is [an upstream bug](https://askubuntu.com/a/1000769/24860) that prevents the service from starting until the server is rebooted.

To work around this problem, add this to your playbook:

```yml
reboot_before_starting_service: true
```

This issue started cropping up in Bionic (Ubuntu 18.04), and was fixed in Focal (Ubuntu 20.04) because the kernel integration is better.

## Issue Tracking

For bugs, feature requests, etc., please visit the [issue tracker](https://gitlab.com/consensus.enterprises/ansible-roles/ansible-role-wireguard-cloud-gateway/-/boards).

## License

GNU AGPLv3

## Author Information

Written by [Colan Schwartz](https://consensus.enterprises/team/colan/) and other folks at [Consensus Enterprises](https://consensus.enterprises/).  To contact us, please use our [Web contact form](https://consensus.enterprises/#contact).

This role was originally forked from [svenkube's wireguard](https://galaxy.ansible.com/svenkube/wireguard).
