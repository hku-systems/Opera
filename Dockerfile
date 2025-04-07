FROM nvidia/cuda:12.0.0-devel-ubuntu22.04 AS build

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y \
        apt-transport-https ca-certificates gnupg software-properties-common wget zlib1g-dev\
        build-essential g++-9 make m4 python3-distutils python3-dev

# Install cmake
RUN wget -O - https://apt.kitware.com/keys/kitware-archive-latest.asc 2>/dev/null | apt-key add -
RUN apt-add-repository 'deb https://apt.kitware.com/ubuntu/ jammy main' && apt-get update && apt-get -y install cmake
