hooks/NN-nazwa.sh        → chroot (po init/overlay/użytkownikach)
hooks/<etap>/NN-nazwa.sh → etapy: pre-bootstrap, post-bootstrap, chroot, pre-image, post-image (poza chroot tylko host)
Przyrostek .host / .chroot wymusza miejsce wykonania. Pliki *.disabled są pomijane.
