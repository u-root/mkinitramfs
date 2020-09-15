// mkintramfs creates a CPIO file for booting Linux.
//
// Each package becomes a symlink to the busybox located at /bin/bb.
package main

import (
	"bufio"
	"flag"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"

	"github.com/u-root/gobusybox/src/pkg/uflag"
	"github.com/u-root/u-root/pkg/cpio"
	"github.com/u-root/u-root/pkg/uroot/initramfs"
)

var defaultRamfs = []cpio.Record{
	cpio.Directory("bbin", 0755),
	cpio.Directory("bin", 0755),
	cpio.Directory("dev", 0755),
	cpio.CharDev("dev/console", 0600, 5, 1),
	cpio.CharDev("dev/tty", 0666, 5, 0),
	cpio.CharDev("dev/null", 0666, 1, 3),
	cpio.CharDev("dev/port", 0640, 1, 4),
	cpio.CharDev("dev/urandom", 0666, 1, 9),
}

var (
	bb          = flag.String("bb", "", "Busybox executable")
	out         = flag.String("out", "", "Output CPIO filename")
	initSymlink = flag.String("init", "bbin/init", "Init command to symlink")
	defaultsh   = flag.String("defaultsh", "elvish", "default shell")
	cmdNames    uflag.Strings
	files       uflag.Strings
)

func init() {
	flag.Var(&cmdNames, "cmd_name", "Command names needing to be symlinked")
	flag.Var(&files, "file", "Files to include in initramfs, sourcePath:pathInCPIO")
}

type flusher interface {
	io.Writer
	Flush() error
}

func flushSafe(f flusher) {
	if err := f.Flush(); err != nil {
		log.Fatal(err)
	}
}

func closeSafe(f io.Closer) {
	if err := f.Close(); err != nil {
		log.Fatal(err)
	}
}

type writer struct {
	cpio.RecordWriter
}

func (w writer) Finish() error { return nil }

func main() {
	flag.Parse()

	// Open the file
	f, err := os.Create(*out)
	if err != nil {
		log.Fatal(err)
	}
	defer closeSafe(f)

	var bw flusher = bufio.NewWriter(f)
	defer flushSafe(bw)

	ifiles := initramfs.NewFiles()
	writeRecord := func(rec cpio.Record) {
		if err := ifiles.AddRecord(rec); err != nil {
			log.Fatalf("could not write record %q: %v", rec.Name, err)
		}
	}

	// Create default records.
	for _, rec := range defaultRamfs {
		writeRecord(rec)
	}

	// Add the busybox binary.
	if *bb != "" {
		if err := ifiles.AddFile(*bb, "bbin/bb"); err != nil {
			log.Fatal(err)
		}
		if len(cmdNames) == 0 {
			log.Fatal("No command names given for busybox.")
		}
		// Create symlinks.
		for _, cmdName := range cmdNames {
			writeRecord(cpio.Symlink(filepath.Join("bbin", cmdName), "bb"))
		}
	} else {
		log.Print("No busybox file specified. Not creating symlinks")
	}

	// Create symlink to init
	writeRecord(cpio.Symlink("init", *initSymlink))

	if *defaultsh != "" {
		writeRecord(cpio.Symlink("bin/defaultsh", "/bbin/"+*defaultsh))
	}
	for _, file := range files {
		paths := strings.Split(file, ":")
		if len(paths) != 2 {
			log.Fatalf("Invalid files format: %v", file)
		}

		dest := strings.TrimLeft(paths[1], "/")
		if err := ifiles.AddFile(paths[0], dest); err != nil {
			log.Fatal(err)
		}
	}

	// Create a CPIO writer.
	w := cpio.Newc.Writer(bw)
	if err := ifiles.WriteTo(writer{w}); err != nil {
		log.Fatal(err)
	}

	// Add trailer.
	if err := cpio.WriteTrailer(w); err != nil {
		log.Fatalf("Could not write trailer: %v", err)
	}
}
