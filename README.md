# KSpaceJet ISMRMRD data

Versioned MRI data manifests and ISMRMRD-compatible raw datasets for KSpaceJet.

Large binary payloads (`.mrd` and `.h5`) are intended to be stored with Git LFS.
The repository metadata makes every dataset traceable, reproducible, and safe to
validate after transfer.

## Repository layout

```text
catalog.yaml                 # Repository-wide dataset index
LICENSES/                    # Shared licence material, when applicable
datasets/<dataset-id>/
  *.mrd | *.h5               # Original raw ISMRMRD/HDF5 data
  dataset.yaml               # Provenance and acquisition summary
  SHA256SUMS                 # SHA-256 checksums of raw data
  LICENSE.txt                # Upstream licence for that dataset
tools/verify-data.sh         # Structural and checksum validation
```

`ocmr-cardiac` additionally groups its raw files in `fully-sampled/` and
`undersampled/`. Those folders may contain raw `.mrd` and `.h5` files only;
their shared metadata remains at `datasets/ocmr-cardiac/`.

## Dataset package contract

Each dataset package keeps only four kinds of material:

- Original `.mrd` or `.h5` data files (including approved raw-data groups).
- `dataset.yaml`, with provenance, ISMRMRD type, supported algorithms, and
  acquisition summary such as coil count, matrix, and trajectory.
- `SHA256SUMS`, with one SHA-256 entry per raw file.
- `LICENSE.txt`, copied from the source distribution without altering its terms.

## Imported sources

| Dataset | Local state | Official source | Terms |
| --- | --- | --- | --- |
| zen-2d-radial-2025 | 1 HDF5 fixture | [Zenodo 14617082](https://zenodo.org/records/14617082) | CC BY 4.0 |
| zen-2d-cartesian-2025 | 3 MRD files | [Zenodo 15223816](https://zenodo.org/records/15223816) | CC BY 4.0 |
| zen-3d-grpe-2023 | 1 HDF5 fixture | [Zenodo 7903282](https://zenodo.org/records/7903282) | CC BY 4.0 |
| zen-multiecho-spiral-2026 | 1 MRD fixture | [Zenodo 18749100](https://zenodo.org/records/18749100) | CC BY 4.0 |
| zen-epi-2021 | 1 HDF5 EPI fixture | [Zenodo 4586829](https://zenodo.org/records/4586829) | CC BY 4.0 |
| ocmr-cardiac | 2 HDF5 fixtures | [OCMR](https://github.com/MRIOSU/OCMR/blob/master/README.md) | research/education agreement |

Each imported dataset.yaml records the stable landing page/DOI, direct source
URL, upstream MD5 or S3 object identity, local SHA-256, retrieval date, and a
summary read from the ISMRMRD header. The project intentionally keeps only
.mrd and .h5 payloads, omitting accompanying sequence, DICOM, NIfTI, and
scanner-native files from the source records.

The repository is a reconstruction-test suite, not a full mirror of upstream
archives. It retains one fixture for each distinct reconstruction path; sampling
density, motion, and otherwise redundant variants are omitted unless they
exercise a separate algorithmic branch.

## Adding data

1. Put the original `.mrd` or `.h5` file(s) in the relevant dataset directory
   (or the approved OCMR group).
2. Complete its `dataset.yaml` from the source documentation and acquisition
   header.
3. Replace `LICENSE.txt` with the original upstream licence text.
4. Regenerate checksums from the repository root:

   ```bash
   (
     cd datasets/<dataset-id>
     find . -mindepth 1 -type f \( -name '*.mrd' -o -name '*.h5' \) -printf '%P\0' \
       | sort -z | xargs -0 sha256sum > SHA256SUMS
   )
   ```

5. Run `./tools/verify-data.sh` before committing.

## Validation

```bash
./tools/verify-data.sh
```

The verifier checks package structure and validates the checksums of every
committed raw payload.
