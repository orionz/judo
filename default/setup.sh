#!/bin/bash

if [ "$JUDO_FIRST_BOOT" ] ; then
  ## do some setup on the first boot only
fi

## use kuzushi to process an erb file
kuzushi-erb example_config.erb > /etc/example_config.conf

