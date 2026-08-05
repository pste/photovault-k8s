#!/bin/bash
# Decifra i manifest di k8s/secrets/ per poterli applicare. Vanno ricifrati con
# ./encrypt.sh prima di committare: il pre-commit hook rifiuta il commit finche'
# il lock file "decrypted" esiste.
export SOPS_AGE_KEY_FILE=$(pwd)/private/age-key.txt

# create lock file
touch decrypted

SECFILES="secrets secrets-pg"

for SECFILE in $SECFILES; do
  FNAME="./k8s/secrets/$SECFILE.yaml"
  if [ -f $FNAME ]; then
    echo "Decrypting $FNAME ..."
    sops --decrypt --in-place $FNAME
  fi
done
