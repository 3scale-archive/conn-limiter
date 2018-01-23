export PROXY_ENDPOINT ?= http://postman-echo.com
export STORAGE_DIR ?= $(PWD)/tmp
export LOG_LEVEL ?= info

BUILDER_IMAGE ?= quay.io/3scale/s2i-openresty-centos7:1.11.2.5-1-rover2
IMAGE_NAME ?= conn-limiter-candidate
REGISTRY ?= quay.io/3scale

S2I_FLAGS ?= --incremental
REMOTE_IMAGE_NAME ?= $(REGISTRY)/$(IMAGE_NAME)

USER := 1000001

build:
	s2i build . $(BUILDER_IMAGE) $(IMAGE_NAME) $(S2I_FLAGS)

tmp:
	umask 0000 && mkdir -p $@

tmp/docker.cid: tmp
	docker run --cidfile $@ --rm -u $(USER) -p 8080:8080 -p 9145:9145 -e LOG_LEVEL=debug -e PROXY_ENDPOINT=http://postman-echo.com $(IMAGE_NAME)

docker-run: tmp/docker.cid
	rm -rf $?

run:
	rover exec openresty -c $(PWD)/conf/nginx.conf -g 'daemon off; error_log stderr $(LOG_LEVEL);'

bash:
	docker run -u $(USER) -it $(IMAGE_NAME) bash


test:
	docker run -u $(USER) -it -e PROXY_ENDPOINT=http://echo-api.3scale.net $(IMAGE_NAME) openresty -c /opt/app-root/src/conf/nginx.conf -g 'daemon on;'

push:
	docker tag $(IMAGE_NAME) $(REMOTE_IMAGE_NAME)
	docker push $(REMOTE_IMAGE_NAME)

release:
	$(MAKE) build push IMAGE_NAME=dwight:ssl S2I_FLAGS=--pull-policy=always

clean:
	rm -rf tmp
	- docker rmi $(IMAGE_NAME)
