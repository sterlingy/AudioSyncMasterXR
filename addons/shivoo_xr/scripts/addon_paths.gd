class_name ShivooXRPaths
extends RefCounted
## Where the addon lives, so the scripts that load its web files by path still work
## when a project mounts the addon somewhere else.
##
## The addon is expected at res://addons/shivoo_xr; everything else is derived from
## this one constant.

const ADDON_DIR := "res://addons/shivoo_xr"
