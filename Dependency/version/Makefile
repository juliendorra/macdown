ALL: version.h

version.h: ../../Tools/version.txt ../../Tools/build-number.txt ../../Tools/generate_version_header.sh ../../Tools/utils.sh
	bash ../../Tools/generate_version_header.sh

.PHONY: install clean distclean

install: ALL

clean:
	-rm version.h 2>/dev/null

distclean: clean
