#!/usr/bin/env bash

# This script prepares some things needed by ./train.sh, e.g. it initializes
# the model and ensures we have the split-up integerized data on disk.

stage=0
words_per_split=10000000  # aim for training on 10 million words per job.  the
                          # aim is to have the jobs last at least a couple of
                          # minutes.  If this leads to having just one job,
                          # we repeat the archive as many times as needed to
                          # get the target length.

if [ $# != 2 ]; then
  echo "Usage: $0 [options] <text-dir> <rnnlm-config-dir> <rnnlm-dir>"
  echo "Sets up the directory <rnnlm-dir> for RNNLM training as done by"
  echo "rnnlm/train.sh, and initializes the model."
  echo " <text-dir> is as validated by rnnlm/validate_data_dir.py"
  echo " <rnnlm-config-dir> is as validated by rnnlm/validate_config_dir.sh."
  exit 1
fi


text_dir=$1
config_dir=$2
dir=$3

set -e
. ./path.sh

if [ $stage -le 0 ]; then
  echo "$0: validating input"

  rnnlm/validate_data_dir.py --spot-check=true $text_dir

  rnnlm/validate_config_dir.sh $config_dir

  if ! mkdir -p $dir; then
    echo "$0: could not create RNNLM dir $dir"
  fi
fi

if [ $stage -le 1 ]; then
  if [ $config_dir != $dir/config ]; then
    echo "$0: copying config directory"
    mkdir -p $dir/config
  # copy expected things from $config_dir to $dir/config.
    for f in words.txt features.txt data_weights.txt oov.txt xconfig; do
      if [ -f $dir/config/$f ] && rm $f
        cp $config_dir/$f $dir/config
      fi
    done
  fi
fi

if [ $stage -le 2 ]; then
  if [ ! -f $text_dir/dev.counts ] || [ $text_dir/dev.counts -ot $text_dir/dev.txt ]; then
    echo "$0: preparing unigram counts in $text_dir"
    rnnlm/get_unigram_counts.sh $text_dir
  fi
fi


if [ $stage -le 3 ]; then
  if [ -f $dir/config/features.txt ]; then
    # prepare word-level features in $dir/word_features.txt
    # first we need the appropriately weighted unigram counts.

    if grep -q '\tunigram\t' $dir/config/features.txt; then
    # we need the unigram probabilities
      rnnlm/ensure_counts_present $text_dir

      rnnlm/get_unigram_probs.py --vocab-file=$dir/config/words.txt \
        --data-weights-file=$dir/config/data_weights.txt \
        >$dir/unigram_probs.txt
      unigram_opt="--unigram-probs=$dir/unigram_probs.txt"
    else
      unigram_opt=
    fi
    rnnlm/make_word_features.py $unigram_opt \
      $dir/config/words.txt $dir/config/features.txt >$dir/word_feats.txt
  else
    [ -f $dir/word_features.txt ] && rm $dir/word_features.txt
  fi
fi

if [ $stage -le 4 ]; then
  echo "$0: preparing split-up integerized text data with weights"
  num_repeats=1
  num_splits=$(rnnlm/get_num_split.sh $words_per_split $text_dir $dir/config/data_weights.txt)
  if [ $num_splits -lt 1 ]; then
    # the script outputs the negative of the num-repeats if the num-splits is 1
    # and the num-repeats is >1.
    num_splits=1
    num_repeats=-$num_splits
  fi

  mkdir -p $dir/text/info
  echo $num_splits >$dir/text/info/num_splits
  echo $num_repeats >$dir/text/info/num_repeats

  # note: the python script treats the empty unknown word as a special case,
  # so if oov.txt is empty we don't have to take any special action.
  rnnlm/prepare_split_data.py --unk-word="$(cat $dir/config/oov.txt)" \
     --vocab-file=$dir/config/words.txt --data-weights-file=$dir/config/data_weights.txt \
     --num-splits=$num_splits $text_dir $dir/text
fi

if [ $stage -le 5 ]; then
  echo "$0: initializing neural net"
  mkdir -p $dir/config/nnet

  steps/nnet3/xconfig_to_configs.py --xonfig-file $dir/config/xconfig \
    --config-dir $dir/config/nnet

  # initialize the neural net.
  nnet3-init $dir/config/nnet/ref.config $dir/0.raw
fi

embedding_dim=$(rnnlm/get_embedding_dim.py $dir/0.raw)

if [ $stage -le 6 ]; then
  echo "$0: initializing embedding matrix"
  if [ -f $dir/config/features.txt ]; then
    # We are using sparse features.
    feat_dim=$(tail -n 1 $dir/config/features.txt | awk '{print $1 + 1;}')

    first_element_opt=
    if grep -q '0\tconstant' $dir/config/features.txt; then
      first_element_opt="--first-element 1.0"
    fi
    # we'll probably make the stddev configurable soon, or maybe just remove it.
    # At some point stability was an issue.
    rnnlm/initialize_matrix.pl $first_element_opt --stddev 0.001 \
      $feat_dim $embedding_dim > $dir/feat_embedding.0.mat

    [ -f $dir/word_embedding.0.mat ] && rm $dir/word_embedding.0.mat
  else
    vocab_size=$(tail -n 1 $dir/config/words.txt | awk '{print $NF + 1}')
    rnnlm/initialize_matrix.pl --first-column 1.0 $vocab_size $embedding_dim > $dir/word_embedding.0.mat

    [ -f $dir/feat_embedding.0.mat ] && rm $dir/feat_embedding.0.mat
  fi
fi