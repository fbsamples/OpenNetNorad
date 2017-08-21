#! /usr/bin/python3

# Copyright (c) 2017-present, Facebook, Inc.
# All rights reserved.

# This source code is licensed under the BSD-style license found in the
# LICENSE file in the root directory of this source tree. An additional grant
# of patent rights can be found in the PATENTS file in the same directory.

from main import app

if __name__ == "__main__":
    app.run(host='127.0.0.1', port=5001)
