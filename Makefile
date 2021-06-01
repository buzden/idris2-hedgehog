export IDRIS2 ?= idris2

lib_pkg = hedgehog.ipkg

docs_pkg = doc.ipkg

.PHONY: all lib doc install clean clean-install repl

all: lib docs

clean-install: clean install

lib:
	${IDRIS2} --build ${lib_pkg}

docs:
	${IDRIS2} --build ${docs_pkg}

install:
	${IDRIS2} --install ${lib_pkg}

clean:
	${IDRIS2} --clean ${lib_pkg}
	${IDRIS2} --clean ${docs_pkg}
	${RM} -r build

# Start a REPL in rlwrap
repl:
	rlwrap -pGreen ${IDRIS2} --find-ipkg src/Hedgehog.idr
