#!/bin/bash

cd ${0%/*}
GOPATH=`pwd` GOBIN=`pwd`/bin go $*
