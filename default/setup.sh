#!/bin/bash

kuzushi-setup  ## this will wait for all the volumes to attach and take care of mounting and formatting them

if [ "$JUDO_FIRST_BOOT" = "true" ] ; then
  ## do some setup on the first boot only
fi

## use kuzushi to process an erb file
kuzushi-erb example_config.erb > /etc/example_config.conf

