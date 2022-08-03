FROM --platform=linux/amd64 ubuntu:20.04

RUN apt-get update
RUN DEBIAN_FRONTEND=noninteractive apt-get install -y make cmake

ADD . /wla-dx
WORKDIR /wla-dx/build
RUN cmake ..
RUN make -j8
