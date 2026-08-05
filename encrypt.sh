#!/bin/bash
# Ricifra i manifest di k8s/secrets/ e rimuove il lock file.
export SOPS_AGE_RECIPIENTS=$(<public-age-keys.txt)
echo ${SOPS_AGE_RECIPIENTS}

SECFILES="secrets secrets-pg"

for SECFILE in $SECFILES; do
  FNAME="./k8s/secrets/$SECFILE.yaml"
  if [ -f $FNAME ]; then
    echo "Encrypting $FNAME ..."
    sops --encrypt --in-place --age ${SOPS_AGE_RECIPIENTS} $FNAME
  fi
done;

# rm lock file
rm decrypted
