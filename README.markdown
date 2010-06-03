# Judo

Judo is a tool for managing a cloud of ec2 servers.  It aims to be both simple
to get going and powerful.

## CONCEPTS

Servers and Groups.  Servers are identified by a naked string.  Groups always
have a colon prefix.  The special group :all refers to all groups.  A name prepended
by a carrot will exclude that selection.

    $ judo restart myserver1                ## this restarts myserver1
    $ judo restart myserver1 myserver2      ## this restarts myserver1 and myserver2
    $ judo restart :default                 ## this restarts all servers in the :default group
    $ judo restart myserver1 :default :db   ## this restarts all servers in the :default group, the :db group, and a server named myserver1
    $ judo restart :all                     ## this restarts all servers in all groups
    $ judo restart :default ^myserver3      ## this restarts all servers in the default group except myserver3
    $ judo restart :all ^:default           ## this restarts all servers except those in the default group

Server: Judo does not track EC2 instances, but Servers, which are a collection
of state, such as EBS volumes, elastic IP addresses and a current EC2 instance
ID.  This allows you to abstract all the elastic EC2 concepts into a more
traditional concept of a static Server.

##	STARTING

You will need an AWS account with EC2, S3 and SDB all enabled.

Setting up a new judo repo named "my_cloud" would look like this:

    $ export AWS_SECRET_ACCESS_KEY="..."
    $ export AWS_ACCESS_KEY_ID="..."
    $ mkdir my_cloud
    $ cd my_cloud
    $ judo setup --bucket BUCKET

The 'judo setup' command will make a .judo folder to store your EC2 keys and S3
bucket.  It will also make a folder named "default" to hold the default server
config.  Feel free to examine the default folder.  It consists of some example
files for a simple server.

To launch a default server you create it

    $ judo create :default            ## make one :default server - have judo pick the name
    ---> Creating server default1...     done (0.6s)
    $ judo create 2:default           ## make two :default servers - have judo pick the name
    ---> Creating server default2...     done (0.5s)
    ---> Creating server default3...     done (0.7s)
    $ judo create myserver1:default   ## make one :default server named myserver1
    ---> Creating server myserver1...    done (0.6s)
    $ judo list
      SERVERS
    --------------------------------------------------------------------------------
      default1             default      v1             m1.small               ebs:0
      default2             default      v1             m1.small               ebs:0
      default3             default      v1             m1.small               ebs:0
      myserver1            default      v1             m1.small               ebs:0
    $ judo start myserver1
    ---> Starting server myserver1...    done (2.3s)
    $ judo launch myserver2:default   ## launch does a create and a start in 1 step
    ---> Creating server myserver2...    done (0.6s)
    ---> Starting server myserver2...    done (2.9s)
    $ judo list
      SERVERS
    --------------------------------------------------------------------------------
      default1             default      v1             m1.small               ebs:0
      default2             default      v1             m1.small               ebs:0
      default3             default      v1             m1.small               ebs:0
      myserver1            default      v1 i-6fdf8d09  m1.small    running    ebs:0
      myserver2            default      v1 i-49cef122  m1.small    running    ebs:0

You can examine a groups config by looking in the group folder in the repo.  The
default group will look something like this.

    $ cat default/config.json
    {
        "ami32":"ami-2d4aa444",       // public ubuntu 10.04 ami - 32 bit
        "ami64":"ami-fd4aa494",       // public ubuntu 10.04 ami - 64 bit
        "user":"ubuntu",              // this is for ssh acccess - defaults to ubuntu not root
        "kuzushi_version": "0.0.54",  // this will pin the version of kuzushi the server will boot with
        "security_group":"judo",
        "example_config": "example_mode",
        "availability_zone":"us-east-1d"
    }

Any changes you make to these files do not stick until you've committed them.
To commit a group do the following.

    $ judo commit :default
    Compiling version 2... done (1.2s)

This will create and start two servers.  One named 'myserver1' and one named
'myserver2'.  You can ssh into 'myserver1' you can type:

    $ judo ssh myserver1

You can stop all the servers in the :default group with:

    $ judo stop :default

##  COMMANDS

       $ judo --help

       judo launch [options] SERVER ...
       judo create [options] SERVER ...
       judo destroy [options] SERVER ...

       # SERVER can be formatted as NAME or NAME:GROUP or N:GROUP
       # where N is the number of servers to create or launch
       # 'launch' only differs from 'create' in that it immediately starts the server

       judo start [options] [SERVER ...]
       judo stop [options] [SERVER ...]
       judo restart [options] [SERVER ...]

       judo commit [options] GROUP

       judo snapshot [options] SERVER SNAPSHOT ## take an ebs snapshot of a server
       judo snapshots [options] [SERVER ...]   ## show current snapshots on servers
       judo animate [options] SNAPSHOT SERVER    ## create a new server from a snapshot
       judo erase [options] SNAPSHOT           ## erase an old snapshot

       judo swap [options] SERVER SERVER     ## swap elastic IP's and names on the two servers

       judo watch [options] SERVER         ## watch the server's boot process
       judo info [options] [SERVER ...]
       judo console [options] [SERVER ...] ## shows AWS console output
       judo ssh [options] [SERVER ...]     ## ssh's into the server

       # SERVER can be formatted as NAME or NAME:GROUP
       # or :GROUP to indicate the whole group.
       # If no servers are listed all servers are assumed.

       judo list [options]    ## lists all servers
       judo groups [options]  ## lists all groups

       judo volumes [options] ## shows all EBS volumes and what they are attached to
       judo ips [options]     ## shows all elastic ips and what they are attached to

## EXAMPLES

An example is worth a thousand words.

A couchdb server:

### ./couchdb/config.json

    {
        "ami32":"ami-2d4aa444",       // public ubuntu 10.04 ami - 32 bit
        "ami64":"ami-fd4aa494",       // public ubuntu 10.04 ami - 64 bit
        "user":"ubuntu",              // this is for ssh acccess - defaults to ubuntu not root
        "security_group":"judo",
        "availability_zone":"us-east-1d"
        "elastic_ip" : true,
        "packages" : "couchdb",
        "volumes" : { "device" : "/dev/sde1",
                      "media"  : "ebs",
                      "size"   : 64,
                      "format" : "ext3",
                      // this is where couchdb looks for its data by default
                      "mount"  : "/var/lib/couchdb/0.10.0",
                      "user"   : "couchdb",
                      "group"  : "couchdb" }
                      // make sure the data is owned by the couchdb user
                      // bounce couch since the data dir changed
    }

### ./couchdb/setup.sh

    service couchdb restart

### ./memcache/config.json
    {
        "ami32":"ami-2d4aa444",       // public ubuntu 10.04 ami - 32 bit
        "ami64":"ami-fd4aa494",       // public ubuntu 10.04 ami - 64 bit
        "user":"ubuntu",              // this is for ssh acccess - defaults to ubuntu not root
        "security_group":"judo",
        "availability_zone":"us-east-1d"
        "elastic_ip" : true,
        "instance_type" : "m1.xlarge"
    }

### ./memcache/setup.sh

    apt-get install -y memcached
    echo 'ENABLE_MEMCACHED=yes' > /etc/default/memcached
    kuzushi-erb memcached.conf.erb > /etc/memcached.conf
    service memcached start

### ./memcache/memcached.conf.erb

    -d
    logfile /var/log/memcached.log
    ## ohai gives memory in Kb so div by 1024 to get megs
    ## use 75% of total ram (* 0.75)
    -m <%= (@system.memory["total"].to_i / 1024 * 0.75).to_i %>
    -u nobody

A redis server with a 2 disk xfs raid 0:

### ./redis/config.json

    {
        "ami32":"ami-2d4aa444",       // public ubuntu 10.04 ami - 32 bit
        "ami64":"ami-fd4aa494",       // public ubuntu 10.04 ami - 64 bit
        "user":"ubuntu",              // this is for ssh acccess - defaults to ubuntu not root
        "security_group":"judo",
        "availability_zone":"us-east-1d"
        "elastic_ip" : true,
        "instance_type" : "m2.xlarge",
        "volumes" : [{ "device" : "/dev/sde1",
                       "media"  : "ebs",
                       "scheduler" : "deadline",
                       "size"   : 16 },
                     { "device" : "/dev/sde2",
                       "media"  : "ebs",
                       "scheduler" : "deadline",
                       "size"   : 16 },
                     { "device"    : "/dev/md0",
                      "media"     : "raid",
                      "mount"     : "/var/lib/redis",
                      "drives"    : [ "/dev/sde1", "/dev/sde2" ],
                      "level"     : 0,
                      "format"    : "xfs" }]
    }

### ./redis/redis-server_1.2.6-1_i686.deb

    ## the deb package can be included the the folder and pushed to the server

### ./redis/setup.sh

    dpkg -i redis-server_1.2.6-1_i686.deb
    chown redis:redis -R /var/lib/redis
    service redis restart

## CONFIG - LAUNCHING THE SERVER

    "instance_type":"m1.small",

Specify the instance type for the server type here. See:
http://aws.amazon.com/ec2/instance-types/.  If nothing is specified m1.small is
used.

   "ami32":"ami-2d4aa444",
   "ami64":"ami-fd4aa494",
   "user":"ubuntu",

This is where you specify the AMI's to use.  The defaults (above) are the
ubuntu 10.04 public AMI's.  The "user" value is which user has the keypair
bound to it for ssh'ing into the server.

    "security_group":"judo",

What security group to launch the server in.  A judo group is created for you
which only has port 22 access.  Manually create new security groups as needed
and name them here.

    "availability_zone":"us-east-1d"

What zone to launch the server in.

    "elastic_ip" : true,

If this is true, an elastic IP will be allocated for the server when it is
created.  This means that if the server is rebooted it will keep the same IP
address.

    "volumes" : [ { "device" : "/dev/sde1", "media" : "ebs", "size" : 64 } ],

You can specify one or more volumes for the group.  If the media is of type
"ebs" judo will create an elastic block device with a number of gigabytes
specified under size.  AWS currently allows values from 1 to 1000.  If the
media is anything other than "ebs" judo will ignore the entry.  The EBS drives
are tied to the server and attached as the specified device when started.  Only
when the server is destroyed are the EBS drives deleted.

## Meta

Created by Orion Henry and Adam Wiggins. Forked from the gem 'sumo'.

Patches contributed by Blake Mizerany, Jesse Newland, Gert Goet, and Tim Lossen

Released under the MIT License: http://www.opensource.org/licenses/mit-license.php

http://github.com/orionz/judo

