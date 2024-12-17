#!/bin/bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

usage() {
  echo -e "usage: ${SCRIPT_NAME} -o <arg> [-b <arg>]
  -o, --output     <arg>    Decision tree .json file with 'type' and 'exit_rm' nodes
  -b, --bed        <arg>    .bed file used to create decision tree node that will link to 'type' and 'exit_rm' nodes
  -h, --help                Print this message and exit"
}

validate() {
  local -r output="${1}"
  local -r bed="${2}"

  # output
  if [[ -z "${output}" ]]; then
    >&2 echo -e "error: missing required -o / --output"
    usage
    exit 2
  fi
  if [[ "${output}" != *.json ]]; then
    echo -e "-o, --output '${output}' is not a '.json' file"
    exit 1
  fi
  if [[ -f "${output}" ]]; then
    echo -e "-o, --output '${output}' already exists"
    exit 1
  fi

  # bed
  if [[ -n "${bed}" ]] && [[ "${bed}" != *.bed ]]; then
    echo -e "-b, --bed '${bed}' is not a '.bed' file"
    exit 1
  fi
}

create() {
  local -r output="${1}"
  local -r bed="${2}"

  # create additional decision tree node if a .bed file was supplied
  local node=""
  if [[ -n "${bed}" ]]; then
    # create outcomes of BOOL_MULTI node based on .bed 
    local outcomes=""
    while IFS=$'\t' read -r chrom chromStart chromEnd other; do
      local chr="${chrom}"
      local start=$((chromStart+1))
      local end=$((chromEnd+1))
      local description="in region ${chrom}:${start}-${end}"

      if [[ -n "${outcomes}" ]]; then
        outcomes+=","
      fi

      outcomes+=$(
cat << EOF

        {
          "description": "${description}",
          "operator": "AND",
          "queries": [{
              "field": "#CHROM",
              "operator": "==",
              "value": "${chr}"
            }, {
              "field": "POS",
              "operator": ">=",
              "value": ${start}
            }, {
              "field": "POS",
              "operator": "<=",
              "value": ${end}
            }
          ],
          "outcomeTrue": {
            "nextNode": "type"
          }
        }
EOF
)
    done < "${bed}"

    # create BOOL_MULTI node
    node+=$(
cat << EOF

    "bed": {
      "label": "${bed%.*}",
      "description": "In ${bed%.*} regions?",
      "type": "BOOL_MULTI",
      "fields": [
        "#CHROM",
        "POS"
      ],
      "outcomes": [${outcomes}
      ],
      "outcomeDefault": {
        "nextNode": "exit_rm"
      },
      "outcomeMissing": {
        "nextNode": "exit_rm"
      }
    },
EOF
)
  fi

  # determine decision tree root node 
  local rootNode=""
  if [[ -n "${bed}" ]]; then
    rootNode="bed"
  else
    rootNode="type"
  fi

  # write decision tree to file
  cat << EOF > "${output}"
{
  "rootNode": "${rootNode}",
  "nodes": {${node}
    "type": {
      "label": "STR?",
      "description": "Is STR?",
      "type": "BOOL",
      "query": {
        "field": "INFO/SVTYPE",
        "operator": "==",
        "value": "STR"
      },
      "outcomeTrue": {
        "nextNode": "pick"
      },
      "outcomeFalse": {
        "nextNode": "filter"
      },
      "outcomeMissing": {
        "nextNode": "filter"
      }
    },
    "pick": {
      "label": "Picked Transcript?",
      "description": "is picked transcript",
      "type": "BOOL",
      "query": {
        "field": "INFO/CSQ/PICK",
        "operator": "==",
        "value": 1
      },
      "outcomeTrue": {
        "nextNode": "up_downstream"
      },
      "outcomeFalse": {
        "nextNode": "exit_rm"
      },
      "outcomeMissing": {
        "nextNode": "exit_rm"
      }
    },
    "up_downstream": {
      "label": "Up or downstream",
      "description": "Up or downstream gene variant",
      "type": "BOOL",
      "query": {
        "field": "INFO/CSQ/Consequence",
        "operator": "contains_any",
        "value": ["upstream_gene_variant","downstream_gene_variant"]
      },
      "outcomeTrue": {
        "nextNode": "exit_rm"
      },
      "outcomeFalse": {
        "nextNode": "unit"
      },
      "outcomeMissing": {
        "nextNode": "unit"
      }
    },
    "unit": {
      "label": "STR Unit",
      "description": "Called unit equals configured unit",
      "type": "BOOL",
      "query": {
        "field": "INFO/RUMATCH",
        "operator": "==",
        "value": true
      },
      "outcomeTrue": {
        "nextNode": "status"
      },
      "outcomeFalse": {
        "nextNode": "exit_vus"
      },
      "outcomeMissing": {
        "nextNode": "exit_vus"
      }
    },
    "status": {
      "label": "Status",
      "description": "STR mutation status",
      "type": "CATEGORICAL",
      "field": "INFO/STR_STATUS",
      "outcomeMap": {
        "pre_mutation": {
          "nextNode": "exit_vus"
        },
        "normal": {
          "nextNode": "exit_lb"
        },
        "full_mutation": {
          "nextNode": "exit_lp"
        }
      },
      "outcomeMissing": {
        "nextNode": "exit_vus"
      },
      "outcomeDefault": {
        "nextNode": "exit_vus"
      }
    },
    "filter": {
      "label": "Filter",
      "description": "Filter pass",
      "type": "BOOL",
      "query": {
        "field": "FILTER",
        "operator": "==",
        "value": [
          "PASS"
        ]
      },
      "outcomeTrue": {
        "nextNode": "vkgl"
      },
      "outcomeFalse": {
        "nextNode": "exit_lq"
      },
      "outcomeMissing": {
        "nextNode": "vkgl"
      }
    },
    "vkgl": {
      "label": "VKGL",
      "description": "VKGL classification",
      "type": "CATEGORICAL",
      "field": "INFO/CSQ/VKGL_CL",
      "outcomeMap": {
        "P": {
          "nextNode": "exit_p"
        },
        "LP": {
          "nextNode": "exit_lp"
        },
        "VUS": {
          "nextNode": "clinVar"
        },
        "LB": {
          "nextNode": "exit_lb"
        },
        "B": {
          "nextNode": "exit_b"
        }
      },
      "outcomeMissing": {
        "nextNode": "clinVar"
      },
      "outcomeDefault": {
        "nextNode": "clinVar"
      }
    },
    "clinVar": {
      "label": "ClinVar",
      "description": "ClinVar classification",
      "type": "BOOL_MULTI",
      "fields": [
        "INFO/CSQ/clinVar_CLNSIG"
      ],
      "outcomes": [
        {
          "description": "Conflict",
          "queries": [
            {
              "field": "INFO/CSQ/clinVar_CLNSIG",
              "operator": "contains_any",
              "value": [ "Conflicting_interpretations_of_pathogenicity" ]
            }
          ],
          "outcomeTrue": {
            "nextNode": "chrom"
          }
        },
        {
          "description": "LP/P",
          "queries": [
            {
              "field": "INFO/CSQ/clinVar_CLNSIG",
              "operator": "contains_any",
              "value": [ "Likely_pathogenic", "Pathogenic" ]
            }
          ],
          "outcomeTrue": {
            "nextNode": "exit_lp"
          }
        },
        {
          "description": "VUS",
          "queries": [
            {
              "field": "INFO/CSQ/clinVar_CLNSIG",
              "operator": "contains_any",
              "value": [ "Uncertain_significance" ]
            }
          ],
          "outcomeTrue": {
            "nextNode": "chrom"
          }
        },
        {
          "description": "B/LB",
          "queries": [
            {
              "field": "INFO/CSQ/clinVar_CLNSIG",
              "operator": "contains_any",
              "value": [ "Likely_benign", "Benign" ]
            }
          ],
          "outcomeTrue": {
            "nextNode": "exit_lb"
          }
        }
      ],
      "outcomeDefault": {
        "nextNode": "chrom"
      },
      "outcomeMissing": {
        "nextNode": "chrom"
      }
    },
    "chrom": {
      "label": "Chromosome",
      "description": "Chromosome 1-22-X-Y-MT",
      "type": "BOOL",
      "query": {
        "field": "#CHROM",
        "operator": "in",
        "value": [
          "chr1",
          "chr2",
          "chr3",
          "chr4",
          "chr5",
          "chr6",
          "chr7",
          "chr8",
          "chr9",
          "chr10",
          "chr11",
          "chr12",
          "chr13",
          "chr14",
          "chr15",
          "chr16",
          "chr17",
          "chr18",
          "chr19",
          "chr20",
          "chr21",
          "chr22",
          "chrX",
          "chrY",
          "chrM"
        ]
      },
      "outcomeTrue": {
        "nextNode": "gene"
      },
      "outcomeFalse": {
        "nextNode": "exit_rm"
      },
      "outcomeMissing": {
        "nextNode": "gene"
      }
    },
    "gene": {
      "label": "Gene",
      "description": "Gene exists",
      "type": "EXISTS",
      "field": "INFO/CSQ/Gene",
      "outcomeTrue": {
        "nextNode": "gnomAD"
      },
      "outcomeFalse": {
        "nextNode": "exit_rm"
      }
    },
    "sv": {
      "label": "SV?",
      "description": "Structural Variant?",
      "type": "EXISTS",
      "field": "INFO/SVTYPE",
      "outcomeTrue": {
        "nextNode": "str"
      },
      "outcomeFalse": {
        "nextNode": "spliceAI"
      }
    },
    "str": {
      "label": "STR?",
      "description": "Short tandem repeat?",
      "type": "BOOL",
      "query": {
        "field": "INFO/SVTYPE",
        "operator": "==",
        "value": "STR"
      },
      "outcomeTrue": {
        "nextNode": "str_status"
      },
      "outcomeFalse": {
        "nextNode": "annotSV"
      },
      "outcomeMissing": {
        "nextNode": "annotSV"
      }
    },
    "str_status": {
      "label": "STR status",
      "description": "Stranger str status (normal, pre_mutation, mutation)",
      "type": "CATEGORICAL",
      "field": "INFO/STR_STATUS",
      "outcomeMap": {
        "full_mutation": {
          "nextNode": "exit_lp"
        },
        "pre_mutation": {
          "nextNode": "exit_vus"
        },
        "normal": {
          "nextNode": "exit_lb"
        }
      },
      "outcomeMissing": {
        "nextNode": "exit_vus"
      },
      "outcomeDefault": {
        "nextNode": "exit_vus"
      }
    },
    "gnomAD": {
      "label": "GnomAD",
      "description": "gnomAD QC filter failure",
      "type": "EXISTS",
      "field": "INFO/CSQ/gnomAD_QC",
      "outcomeTrue": {
        "nextNode": "sv"
      },
      "outcomeFalse": {
        "nextNode": "gnomAD_AF"
      }
    },
    "gnomAD_AF": {
      "label": "",
      "description": "gnomAD",
      "type": "BOOL_MULTI",
      "fields": [
        "INFO/CSQ/gnomAD_FAF99",
        "INFO/CSQ/gnomAD_HN"
      ],
      "outcomes": [
        {
          "description": "Filtering allele Frequency (99% confidence) >= 0.02 or Number of Homozygotes > 5",
          "operator": "OR",
          "queries": [
            {
              "field": "INFO/CSQ/gnomAD_FAF99",
              "operator": ">=",
              "value": 0.02
            },
            {
              "field": "INFO/CSQ/gnomAD_HN",
              "operator": ">=",
              "value": 5
            }
          ],
          "outcomeTrue": {
            "nextNode": "exit_lb"
          }
        }
      ],
      "outcomeDefault": {
        "nextNode": "sv"
      },
      "outcomeMissing": {
        "nextNode": "sv"
      }
    },
    "annotSV": {
      "label": "AnnotSV",
      "description": "AnnotSV classification",
      "type": "CATEGORICAL",
      "field": "INFO/CSQ/ASV_ACMG_class",
      "outcomeMap": {
        "5": {
          "nextNode": "exit_p"
        },
        "4": {
          "nextNode": "exit_lp"
        },
        "3": {
          "nextNode": "exit_vus"
        },
        "2": {
          "nextNode": "exit_lb"
        },
        "1": {
          "nextNode": "exit_b"
        }
      },
      "outcomeMissing": {
        "nextNode": "spliceAI"
      },
      "outcomeDefault": {
        "nextNode": "spliceAI"
      }
    },
    "spliceAI": {
      "label": "SpliceAI",
      "description": "SpliceAI prediction",
      "type": "BOOL_MULTI",
      "fields": [
        "INFO/CSQ/SpliceAI_pred_DS_AG",
        "INFO/CSQ/SpliceAI_pred_DS_AL",
        "INFO/CSQ/SpliceAI_pred_DS_DG",
        "INFO/CSQ/SpliceAI_pred_DS_DL"
      ],
      "outcomes": [
        {
          "description": "Delta score (acceptor/donor gain/loss) > 0.42",
          "operator": "OR",
          "queries": [
            {
              "field": "INFO/CSQ/SpliceAI_pred_DS_AG",
              "operator": ">",
              "value": 0.42
            },
            {
              "field": "INFO/CSQ/SpliceAI_pred_DS_AL",
              "operator": ">",
              "value": 0.42
            },
            {
              "field": "INFO/CSQ/SpliceAI_pred_DS_DG",
              "operator": ">",
              "value": 0.42
            },
            {
              "field": "INFO/CSQ/SpliceAI_pred_DS_DL",
              "operator": ">",
              "value": 0.42
            }
          ],
          "outcomeTrue": {
            "nextNode": "exit_lp"
          }
        },
        {
          "description": "Delta score (acceptor/donor gain/loss) > 0.13",
          "operator": "OR",
          "queries": [
            {
              "field": "INFO/CSQ/SpliceAI_pred_DS_AG",
              "operator": ">",
              "value": 0.13
            },
            {
              "field": "INFO/CSQ/SpliceAI_pred_DS_AL",
              "operator": ">",
              "value": 0.13
            },
            {
              "field": "INFO/CSQ/SpliceAI_pred_DS_DG",
              "operator": ">",
              "value": 0.13
            },
            {
              "field": "INFO/CSQ/SpliceAI_pred_DS_DL",
              "operator": ">",
              "value": 0.13
            }
          ],
          "outcomeTrue": {
            "nextNode": "exit_vus"
          }
        }
      ],
      "outcomeDefault": {
        "nextNode": "utr5"
      },
      "outcomeMissing": {
        "nextNode": "utr5"
      }
    },
    "utr5": {
      "label": "5' UTR",
      "description": "5' UTR",
      "type": "EXISTS",
      "field": "INFO/CSQ/five_prime_UTR_variant_consequence",
      "outcomeTrue": {
        "nextNode": "exit_vus"
      },
      "outcomeFalse": {
        "nextNode": "capice"
      }
    },
    "capice": {
      "label": "Capice",
      "description": "CAPICE prediction > 0.5",
      "type": "BOOL",
      "query": {
        "field": "INFO/CSQ/CAPICE_SC",
        "operator": ">",
        "value": 0.5
      },
      "outcomeTrue": {
        "nextNode": "exit_lp"
      },
      "outcomeFalse": {
        "nextNode": "exit_lb"
      },
      "outcomeMissing": {
        "nextNode": "exit_vus"
      }
    },
    "exit_lq": {
      "label": "Low Quality",
      "description": "Low Quality",
      "type": "LEAF",
      "class": "LQ"
    },
	"exit_rm": {
      "label": "",
      "description": "Remove",
      "type": "LEAF",
      "class": "RM"
    },
    "exit_b": {
      "label": "B",
      "description": "Benign",
      "type": "LEAF",
      "class": "B"
    },
    "exit_lb": {
      "label": "LB",
      "description": "Likely Benign",
      "type": "LEAF",
      "class": "LB"
    },
    "exit_vus": {
      "label": "VUS",
      "description": "Uncertain Significance",
      "type": "LEAF",
      "class": "VUS"
    },
    "exit_lp": {
      "label": "LP",
      "description": "Likely Pathogenic",
      "type": "LEAF",
      "class": "LP"
    },
    "exit_p": {
      "label": "P",
      "description": "Pathogenic",
      "type": "LEAF",
      "class": "P"
    }
  }
}
EOF
}

main() {
  local -r args=$(getopt -a -n pipeline -o o:b:h --long output:,bed:,help -- "$@")
  # shellcheck disable=SC2181
  if [[ $? != 0 ]]; then
    usage
    exit 2
  fi

  local output=""
  local bed=""

  eval set -- "${args}"
  while :; do
    case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    -o | --output)
      output="$2"
      shift 2
      ;;
    -b | --bed)
      bed="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      usage
      exit 2
      ;;
    esac
  done

  validate "${output}" "${bed}"
  create "${output}" "${bed}"
}

main "${@}"
