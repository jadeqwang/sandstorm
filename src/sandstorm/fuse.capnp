# Sandstorm - Personal Cloud Sandbox
# Copyright (c) 2014, Kenton Varda <temporal@gmail.com>
# All rights reserved.
#
# This file is part of the Sandstorm platform implementation.
#
# Sandstorm is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# Sandstorm is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public
# License along with Sandstorm.  If not, see
# <http://www.gnu.org/licenses/>.

@0x9532f0cb4c62f0a0;
# This file defines a Cap'n Proto interface mirroring FUSE. Adapter code is provided to implement
# the /dev/fuse protocol in terms of this interface.
#
# Currently, only read operations are defined.

$import "/capnp/c++.capnp".namespace("sandstorm::fuse");

using DateInNs = Int64;
using DurationInNs = UInt64;

interface Node {
  # A node in the filesystem tree.

  lookup @0 (name :Text) -> (node :Node, ttl :DurationInNs);
  # Look up a child node. Only makes sense for directory nodes; others will throw exceptions.
  # `name` must never be "." nor "..", and implementations must throw exceptions in these cases.
  # It is the caller's responsibility to implement "." and ".." lookup if desired.

  getAttributes @1 () -> (attributes :Attributes, ttl :DurationInNs);

  openAsFile @2 () -> (file :File);
  openAsDirectory @3 () -> (directory :Directory);
  readlink @4 () -> (link :Text);

  enum Type {
    unknown @0;
    blockDevice @1;
    characterDevice @2;
    directory @3;
    fifo @4;
    symlink @5;
    regular @6;
    socket @7;
  }

  struct Attributes {
    # Corresponds to `struct stat`; see stat(2) man page.
    #
    # We split out the `mode` field into `type` and permissions.

    inodeNumber @0 :UInt64;
    # AFAIK, this is only used to fill in the results of stat(). It doesn't have to be meaningful,
    # although Linux doesn't like it if it is zero. Always setting to 1 works fine.

    type @1 :Type;

    permissions @2 :UInt32;
    # Traditional 12-bit permissions mask:
    # 0-2: Executable/writable/readable by everyone.
    # 3-5: Executable/writable/readable by group.
    # 6-8: Executable/writable/readable by owner.
    # 9: Sticky (only owner can rename/delete directory contents)
    # 10: Set-group-ID. Multiple overloaded meanings. See stat(2).
    # 11: Set-user-ID.

    linkCount @3 :UInt32;
    ownerId @4 :UInt32;
    groupId @5 :UInt32;
    deviceMajor @6 :UInt32;  # Only for type = device.
    deviceMinor @7 :UInt32;  # Only for type = device.
    size @8 :UInt64;         # Only for regular files and symlinks.
    blockCount @9 :UInt64;   # Only for type = block device.
    blockSize @10 :UInt32;   # Only for type = block device.
    lastAccessTime @11 :DateInNs;
    lastModificationTime @12 :DateInNs;
    creationTime @13 :DateInNs;
  }
}

interface File {
  # An open file.

  read @0 (offset :UInt64, size :UInt32) -> (data :Data);
  # Read data from file.  This *must* read the entire amount requested except in case of EOF.
}

interface Directory {
  # An open directory.

  read @0 (offset :UInt64, count :UInt32) -> (entries :List(Entry));
  # Read a list of entries. Always returns exactly `count` items unless the end of the directory is
  # reached.
  #
  # By convention, "." and ".." should be included in the returned list, even though `lookup` will
  # never be called (and must fail) on these names. (In practice, the effect of omitting "." and
  # ".." is that they will not appear in e.g. `ls -a` output; it's unclear whether this actually
  # breaks anything.)

  struct Entry {
    # Corresponds to linux_dirent; see getdents(2).

    inodeNumber @0 :UInt64;
    # See comment in Node.Attributes.

    nextOffset @1 :UInt64;
    # Offset of the position in the directory immediately after this entry.  This value may be
    # echoed back in a subsequent read() to start from the position after this entry.

    type @2 :Node.Type = unknown;
    # `type` is optional.  If it is inconvenient to determine (e.g. would require an additional
    # system call), set it to `unknown`.  This forces the caller to make a separate
    # `getAttributes()` request to determine the type.

    name @3 :Text;
    # Name of the entry.  Must not include slashes nor NUL characters.

    # TODO(someday):  Perhaps return a Node to implement "readdirplus"?
  }
}
