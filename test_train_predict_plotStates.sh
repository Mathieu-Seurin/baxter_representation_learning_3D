#!/bin/bash

function has_command_finish_correctly {
    if [ "$?" -ne "0" ]
    then
        exit
    else
        return 0
    fi
}


# CONFIG OPTIONS:
# -use_cuda
# -use_continuous
# -params.sigma  is CONTINUOUS_ACTION_SIGMA
# -params.mcd is MAX_COS_DIST_AMONG_ACTIONS_THRESHOLD
# -data_folder options: DATA_FOLDER (Dataset to use):
#          staticButtonSimplest, mobileRobot, simpleData3D, pushingButton3DAugmented, babbling')
qlua script.lua  -use_cuda -data_folder staticButtonSimplest  # TODO:  TRY FIRST DISCRETE< COMPARE AND SWITCH TO CONTINUOUS
has_command_finish_correctly
#-mcd 0.8 -sigma 0.8
# -data_folder staticButtonSimplest
# -data_folder mobileRobot
th imagesAndReprToTxt.lua -use_cuda -data_folder staticButtonSimplest
has_command_finish_correctly

python generateNNImages.py 10
has_command_finish_correctly

#   ----- includes the call to:
#                th create_all_reward.lua
#                th create_plotStates_file_for_all_seq.lua
python plotStates.py
has_command_finish_correctly

python report_results.py
has_command_finish_correctly
