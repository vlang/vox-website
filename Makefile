V ?= v
TRAFFIC_MODULE_DIR ?= $(HOME)/code/traffic
VPATH := $(abspath $(TRAFFIC_MODULE_DIR)/..)|@vlib|@vmodules
VFLAGS ?= -memory-limit 10G

.PHONY: build run test check fmt smoke

build:
	mkdir -p bin
	$(V) $(VFLAGS) -path '$(VPATH)' -prod -o bin/vox-website .

run: build
	./bin/vox-website

test:
	$(V) $(VFLAGS) -path '$(VPATH)' test .

check:
	$(V) fmt -verify main.v main_test.v
	$(V) $(VFLAGS) -path '$(VPATH)' -check .

fmt:
	$(V) fmt -w main.v main_test.v

smoke: build
	python3 scripts/smoke_test.py
