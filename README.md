## XenServer API Adapter

[ ![Codeship Status for nowhere-cloud/xen-api](https://app.codeship.com/projects/4d2a9250-d4a2-0134-07f4-1aaf05821783/status?branch=master)](https://app.codeship.com/projects/202210)

This repository contains the source code of interacting a XenServer Hypervisor over its XML-RPC API.

Example: [Communicate over RabbitMQ](amqpd.rb)

---

### Requirements // システム必要条件 // 系統要求
* Ruby >= 2.3.0 w/ Bundler
* Linux (M$ Windows から残念です、申し訳ございません) (不支援 M$ Windows)

### How To use/Test? // 使い方 (英語のみ) // 食用方法 (English Only)
```sh
# Set Environment Variables
cd .../ruby-xenapi-new
export XEN_SERVER_ADDR = "192.168.0.123"
export XEN_SERVER_PORT = 443
export XEN_SERVER_USER = 'root'
export XEN_SERVER_PASS = 'foo-change-me'

# Play the API on Interactive Ruby Script Environment
irb --noecho --noprompt

require xenapi.rb

# Login
xenapi = XenApi.new

# logout
xenapi.logout

```

![Screenshot](screenshot.png?raw=true)
### Acknowledgements
* http://discussions.citrix.com/topic/244784-how-to-get-ip-address-of-vm-network-adapters/
* https://gist.github.com/ascendbruce/7070951
* https://stelfox.net/blog/2012/02/rubys-xmlrpc-client-and-ssl/

### Documentations
* TODO

### Todo
* Deal with the 'struct' on 'last_booted_record'

### Footnote
* All Chinese (Traditional Script) and Japanese descriptions in this document are Machine-Translated Results.
While Japanese results are interpreted afterwards, quality of Chinese descriptions are not assured.
