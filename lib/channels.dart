import 'package:flutter/services.dart';

/// Channel handles whose names are used from more than one file, kept in one
/// place so a retyped literal cannot silently split a channel. Channels used
/// by a single file keep their local consts.
const MethodChannel kRoleChannel = MethodChannel('glimpr/role');
const MethodChannel kEncodeChannel = MethodChannel('glimpr/encode');
