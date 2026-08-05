#!/bin/bash
# Decifra i manifest di k8s/site/ per poterli applicare. Vanno ricifrati con
# ./encrypt.sh prima di committare: il pre-commit hook rifiuta il commit finche'
# il lock file "decrypted" esiste.
export SOPS_AGE_KEY_FILE=$(pwd)/private/age-key.txt

# create lock file
touch decrypted

SITEFILES="secrets secrets-pg storage ingress"

for SITEFILE in $SITEFILES; do
  FNAME="./k8s/site/$SITEFILE.yaml"
  if [ -f $FNAME ]; then
    echo "Decrypting $FNAME ..."
    sops --decrypt --in-place $FNAME
  fi
done
