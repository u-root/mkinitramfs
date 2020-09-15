load("@com_github_u_root_gobusybox//src:gobb2.bzl", "GoBusyboxBinary", "go_busybox")

def _initramfs_impl(ctx):
    """
    _initramfs_template implements the initramfs rule.

    It creates a CPIO file for booting Linux. Each package becomes a symlink to
    the busybox located at /bin/bb.

    Args:
        ctx: rule context.

    Returns:
        A CPIO file
    """
    out = ctx.actions.declare_file("%s.cpio" % ctx.attr.name)

    args = ctx.actions.args()
    bbexec = ctx.attr.busybox[GoBusyboxBinary].executable
    args.add("--bb", bbexec.path)
    args.add("--out", out.path)
    args.add("--defaultsh", ctx.attr.default_shell)

    cmd_names = []
    for name in ctx.attr.busybox[GoBusyboxBinary].command_names:
        if name in cmd_names:
            fail("Two commands have the same name '%s'" % name)
        cmd_names.append(name)
        args.add("--cmd_name", name)

    inputs = [bbexec]
    for key, value in ctx.attr.files.items():
        if len(key.files.to_list()) > 1:
            fail("each files element must correspond to a rule that produces exactly one file")
        for f in key.files.to_list():
            inputs.append(f)
            args.add("--file", "%s:%s" % (f.path, value))

    ctx.actions.run(
        mnemonic = "MakeInitramfs",
        inputs = inputs,
        outputs = [out],
        arguments = [args],
        executable = ctx.executable._mkinitramfs,
    )
    return [DefaultInfo(
        files = depset([out]),
        data_runfiles = ctx.runfiles(files = [out]),
    )]

initramfs_impl = rule(
    attrs = {
        "busybox": attr.label(
            mandatory = True,
            providers = [GoBusyboxBinary],
        ),
        "default_shell": attr.string(
            default = "elvish",
        ),
        "_mkinitramfs": attr.label(
            executable = True,
            cfg = "host",
            allow_files = True,
            default = Label("//cmd/mkinitramfs"),
        ),
        "files": attr.label_keyed_string_dict(
            allow_files = True,
            allow_empty = True,
            cfg = "target",
        ),
    },
    implementation = _initramfs_impl,
)

def _intersect_lists(xs, ys):
    return [x for x in xs for y in ys if x == y]

def initramfs(name, uinit = "", commands = [], binaries = [], default_shell = "elvish", files = {}):
    """
    initramfs creates a busybox initramfs.

    It creates a CPIO file for booting Linux. Each package becomes a symlink to
    the busybox located at /bin/bb.

    Args:
        name: cpio name.
        commands: busybox commands to include in the initramfs, if no busybox
            was specified.
        uinit: like any other busybox command, but not included in the _shell
            generated rule.
        binaries: binaries not part of the Go busybox.
        default_shell: the command to use as the shell, either rush or elvish
        files: additional files to include in the initramfs
    """
    all_files = {b: "/bin/" + Label(b).name for b in binaries}
    duplicate_targets = _intersect_lists(all_files.keys(), files.keys())
    duplicate_files = _intersect_lists(all_files.values(), files.values())
    if duplicate_targets:
        fail("duplicate initramfs targets: %s" % duplicate_targets)
    if duplicate_files:
        fail("duplicate initramfs filenames: %s" % duplicate_files)
    all_files.update(files)

    # Generate a busybox if none was specified.
    if uinit:
        allcmds = commands + [uinit]
    else:
        allcmds = commands

    go_busybox(
        name = "%s_bb" % name,
        cmds = allcmds,
    )

    if uinit:
        go_busybox(
            name = "%s_shell_bb" % name,
            cmds = commands,
        )
        initramfs_impl(
            name = "%s_shell" % name,
            busybox = ":%s_shell_bb" % name,
            default_shell = default_shell,
            files = all_files,
        )

    initramfs_impl(
        name = name,
        busybox = ":%s_bb" % name,
        default_shell = default_shell,
        files = all_files,
    )
