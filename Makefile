ALLS ?= oasis-core oasis-sdk oasis-web3-gateway cli emerald-paratime
BUILDS ?= oasis-core oasis-web3-gateway cli emerald-paratime

.PHONY: oasis-core oasis-web3-gateway cli emerald-paratime

build: $(BUILDS)

$(BUILDS):
	@ echo "\n===================== $@ =====================\n"; \
	cd $@; \
	[ "$(MAKECMDGOALS)" = .clean ] && t=clean || t=$(target); \
	for go_mod in go.mod go/go.mod ; do \
		[ -f "$$go_mod" ] || continue; \
		go_ver=`sed -n 's/^toolchain //p' $$go_mod`; \
		[ -n "$$go_ver" ] && go_cmd=`bash -c "compgen -c $$go_ver"`; \
		[ -n "$$go_cmd" ] && break; \
		go_ver=`sed -n 's/^go //p' $$go_mod`; \
		[ -n "$$go_ver" ] && go_cmd=`bash -c "compgen -c go$$go_ver"`; \
	done; \
	export ECHO="echo -e"; \
	set -x; \
	export OASIS_GO=$${go_cmd:-go}; \
	if [ $@ = oasis-core ] ; then \
		export OASIS_UNSAFE_SKIP_AVR_VERIFY=1; \
		export OASIS_UNSAFE_SKIP_KM_POLICY=1; \
		export OASIS_UNSAFE_ALLOW_DEBUG_ENCLAVES=1; \
		export OASIS_BADGER_NO_JEMALLOC=1; \
	fi; \
	make $$t

.clean: $(BUILDS)

clean:
	@make .clean


sync:
	@ for x in $(ALLS) ; do \
        echo "\n===================== $$x =====================\n"; \
        cd $$x; \
        rmt; \
        cd -; \
    done

tig:
	@ for x in $(ALLS) ; do \
        cd $$x; \
        echo -n "\033]0;======= $$x ========\007"; \
		[ -z "$(param)$(params)" ] && extra="HEAD `git tag -l 'hela-*'`"; \
        $@ $(param) $(params) $$extra; \
        cd - >/dev/null; \
    done

status:
	@ for x in $(ALLS) ; do \
        cd $$x; \
        echo "\n===================== $$x =====================\n"; \
        git branch -vv; \
        echo "---"; \
        git $@ $(param) $(params); \
        cd - >/dev/null; \
    done

stash checkout tag push fetch branch commit dt:
	@ for x in $(ALLS) ; do \
        cd $$x; \
        echo "\n===================== $$x =====================\n"; \
        git $@ $(param) $(params); \
        cd - >/dev/null; \
    done
