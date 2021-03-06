require 'nn'
require 'optim'
require 'image'
require 'torch'
require 'xlua'
require 'math'
require 'string'
require 'nngraph'
require 'MSDC'
require 'functions'
require 'printing'
require "Get_Images_Set"
require 'optim_priors'
require 'definition_priors'

-- THIS IS WHERE ALL THE CONSTANTS SHOULD COME FROM
-- See const.lua file for more details
require 'const'
-- try to avoid global variable as much as possible


--Differences with respect to script.lua
-- For both ML-DDPG and DDPG an ERD, batch-normalization,
-- an L2 penalty c = 0:002 on the critic weights and “soft”
-- updates of the target networks with  = 10􀀀3 are used to
-- stabilize the learning. Adam [24] is used for learning the
-- weights of all three DNNs with a base learning rate of m =
-- 10􀀀3, a = 10􀀀4 and c = 10􀀀3 for the model, actor and
-- critic respectively. The hidden layers of all three networks
-- contain 100 neurons each. a = 50 and m = 10 and
--  =0:99.
-- 40000 learning steps for the 2-link arm
-- problem and 30000 learning steps for the octopus. Every 100
-- learning steps the policy  is evaluated
--settling time s of the learning curve is then defined as
-- the number of learning steps after which the learning curve
-- enters and remains within a band  of the final value Rf :
-- s = Tt  arg maxj (|Rbar_f - R_j|>=epsilon* R_f)
-- In this paper c (learning steps) = 1000
-- epsilon (band of the final value Rbar_f) =  0:05 .
-- Octopus BenchmarK: The reward from the environment is based on the Euclidean distance D between the food and the segment (efector)
--2-link arm ben


RESNET_VERSION = 18
USE_CUDA = false
--
-- BATCH_SIZE = 8
DIMENSION_ACTION = 2
DIMENSION_IN = 2
DIMENSION_OUT = DIMENSION_ACTION
NUM_CLASS = 3 --3 DIFFERENTS REWARDS

-- if USE_CUDA then
--     require 'cunn'
--     require 'cutorch'
--     require 'cudnn'  --If trouble, installing, follow step 6 in https://github.com/jcjohnson/neural-style/blob/master/INSTALL.md
--     -- and https://github.com/soumith/cudnn.torch  --TODO: set to true when speed issues rise
--     -- cudnn.benchmark = true -- uses the inbuilt cudnn auto-tuner to find the fastest convolution algorithms.
--     --                -- If this is set to false, uses some in-built heuristics that might not always be fastest.
--     -- cudnn.fastest = true -- this is like the :fastest() mode for the Convolution modules,
--                  -- simply picks the fastest convolution algorithm, rather than tuning for workspace size
--     tnt = require 'torchnet'
--     vision = require 'torchnet-vision'  -- Install via https://github.com/Cadene/torchnet-vision
-- end



function train_batch(Models,priors_used)
   local rep_criterion=get_Rep_criterion()
   local prop_criterion=get_Prop_criterion()
   local caus_criterion=get_Caus_criterion()
   local temp_criterion=nn.MSDCriterion() -- MEAN square distance see https://github.com/torch/nn/blob/master/doc/criterion.md
   local predict_reward_criterion= nn.MSECriterion() --TODO
   local mse_criterion = nn.MSECriterion()

   -- create closure to evaluate f(X) and df/dX in backprop
   local feval = function(x)
      local loss_rep, loss_caus, loss_prop, loss_temp, loss_reward_closer, loss_fix, loss_reward_pred, loss_mse = 0, 0, 0, 0, 0, 0, 0, 0
      -- just in case:
      collectgarbage()

      local batch, action1, action2
      -- get new parameters
      if x ~= parameters then
         parameters:copy(x)
      end

      -- reset gradients
      gradParameters:zero()

      --See Get_Images_Set.lua file for selecting the images for each prior, which is key for each prior's loss function input
      --===========
      local mode = INVERSE_MODEL
      if applying_prior(priors_used, mode) then
          print('Backprop batch step for Inverse Model')
          batch=getRandomBatchFromSeparateList(BATCH_SIZE,mode)
          loss_temp, grad=backprop(Models,temp_criterion, batch,COEF_TEMP)
          TOTAL_LOSS = loss_temp + TOTAL_LOSS_TEMP
      end
      --====PRIORS LOSSES:
      mode= TEMP --Same for continuous or discrete actions
      if applying_prior(priors_used, mode) then
          batch=getRandomBatchFromSeparateList(BATCH_SIZE,mode)
          loss_temp, grad=doStuff_temp(Models,temp_criterion, batch,COEF_TEMP)
          TOTAL_LOSS_TEMP = loss_temp + TOTAL_LOSS_TEMP
      end

      mode= PROP
      if applying_prior(priors_used, mode) then
          batch, action1, action2 = getRandomBatchFromSeparateList(BATCH_SIZE,mode)
          loss_prop, gradProp=doStuff_Prop(Models,prop_criterion,batch,COEF_PROP, action1, action2)
          TOTAL_LOSS_PROP = loss_prop + TOTAL_LOSS_PROP
      end

      --==========
      mode= CAUS  --Not applied for BABBLING data (sparse rewards)
      if applying_prior(priors_used, mode) then
        batch, action1, action2 = getRandomBatchFromSeparateList(BATCH_SIZE,mode)
        loss_caus, gradCaus=doStuff_Caus(Models,caus_criterion,batch,COEF_CAUS, action1, action2)
        TOTAL_LOSS_CAUS = loss_caus + TOTAL_LOSS_CAUS
      end

      --==========
      mode= REP
      if applying_prior(priors_used, mode) then
          batch, action1, action2 = getRandomBatchFromSeparateList(BATCH_SIZE,mode)
          loss_rep, gradRep=doStuff_Rep(Models,rep_criterion,batch,COEF_REP, action1, action2)
          TOTAL_LOSS_REP = loss_rep + TOTAL_LOSS_REP
      end

      mode= BRING_CLOSER_REWARD
      if applying_prior(priors_used, mode) then
          batch = getRandomBatchFromSeparateList(BATCH_SIZE,mode)
          loss_reward_closer, gradClose=doStuff_temp(Models,temp_criterion,batch,COEF_CLOSE) --Just minimizing mse criterion, so we can use temp criterion
          TOTAL_LOSS_CLOSE = loss_reward_closer + TOTAL_LOSS_CLOSE
      end

      mode = BRING_CLOSER_REF_POINT
      if applying_prior(priors_used, mode) then
          batch = getRandomBatchFromSeparateList(BATCH_SIZE, mode)
          loss_fix, gradClose=doStuff_temp(Models,temp_criterion,batch,COEF_FIX) --Just minimizing mse criterion, so we can use temp criterion
          TOTAL_LOSS_FIX = loss_fix + TOTAL_LOSS_FIX
      end

      mode= REWARD_PREDICTION_CRITERION
      if ACTIVATE_PREDICTIVE_PRIORS then -- TODO CHANGE: applying_prior(priors_used, mode) then
          batch = getRandomBatchFromSeparateList(BATCH_SIZE,mode)
          loss_reward_pred, gradRewardPred = get_loss_and_gradient_for_reward_pred(Models,reward_prediction_criterion,batch,COEF_REWARD_PRED) --Just minimizing mse criterion, so we can use temp criterion
          TOTAL_LOSS_REWARD_PRED = TOTAL_LOSS_REWARD_PRED + loss_reward_pred
      end

      --TODO comparison with L1 smooth distance criterion (takes L1 norm in (-inf, -1) and (1, +inf) and L2 in the center of the interval for faster convergence updates far outside the iminma)
      --TODO Comparison with Torch cosDistance criterion
      --NOTE: gradParameters  shouldnt be here  the sum of all gradRep, gradCaus, etc? No because
      --GradParameters is a tensor containing the internal gradient of all model's parameters
      -- So the sum of gradients is already present in there
      return loss_rep+loss_caus+loss_prop+loss_temp+loss_fix+loss_reward_closer+loss_reward_pred, gradParameters
    end

    --sgdState = sgdState or { learningRate = LR, momentum = mom,learningRateDecay = 5e-7,weightDecay=coefL2 }
    --parameters, loss=optim.sgd(feval, parameters, sgdState)
    optimState={learningRate=LR, learningRateDecay=LR_DECAY}

    if SGD_METHOD == 'adagrad' then
        parameters, loss = optim.adagrad(feval, parameters, optimState)
    elseif SGD_METHOD == 'adam' then
        parameters, loss = optim.adam(feval, parameters, optimState)
    else
        parameters, loss = optim.adamax(feval, parameters, optimState)
    end

    -- loss[1] table of one value transformed in just a value
    -- grad[1] we use just the first gradient to print the figure (there are 2 or 4 gradient normally)
    return loss[1], grad
end

function train(Models, priors_used)

   LOG_SEQ_USED = {}

    local NB_BATCHES= math.ceil(NB_SEQUENCES*AVG_FRAMES_PER_RECORD/BATCH_SIZE/(4+4+2+2))
    --AVG_FRAMES_PER_RECORD to get an idea of the total number of images
    --div by 12 because the network sees 12 images per iteration (i.e. record)
    -- (4*2 for rep and prop +  2*2 for temp and caus = 12)
    print(NB_SEQUENCES..' : sequences. '..NB_BATCHES..' batches')
    print("Number of epochs : ", NB_EPOCHS)
    for epoch=1, NB_EPOCHS do
       print('--------------Epoch : '..epoch..' ---------------')

       TOTAL_LOSS_TEMP,TOTAL_LOSS_CAUS,TOTAL_LOSS_PROP, TOTAL_LOSS_REP, TOTAL_LOSS_CLOSE, TOTAL_LOSS_FIX, TOTAL_LOSS_REWARD_PRED, TOTAL_LOSS_MSE, TOTAL_LOSS = 0,0,0,0,0,0,0,0, 0
       xlua.progress(0, NB_BATCHES)
       for numBatch=1, NB_BATCHES do
          Loss, Grad = train_batch(Models,priors_used)
          xlua.progress(numBatch, NB_BATCHES)
       end

    --    print("Loss Temp", TOTAL_LOSS_TEMP/NB_BATCHES/BATCH_SIZE)
    --    print("Loss Prop", TOTAL_LOSS_PROP/NB_BATCHES/BATCH_SIZE)
    --    print("Loss Caus", TOTAL_LOSS_CAUS/NB_BATCHES/BATCH_SIZE)
    --    print("Loss Rep", TOTAL_LOSS_REP/NB_BATCHES/BATCH_SIZE)
       print("Loss Inverse Model:", TOTAL_LOSS/NB_BATCHES/BATCH_SIZE)

       save_model(Models.Model1, NAME_SAVE, SAVE_MODEL_T7_FILE) --TODO Do we need to write NB_EPOCH TIMES? isnt enough the last time to write once and not overwrite NB_EPOCH TIMES?
   end
   log_model_params()
   return Models.Model1, NAME_SAVE
end



local function main(params)
    print("\n\n>> predictive_priors_script.lua: main model builder")
    RUNNING_INVERSE_MODEL = true
    if RUN_FORWARD_MODEL then
        set_hyperparams(params, 'Fwd', true)
    elseif RUNNING_INVERSE_MODEL then
        set_hyperparams(params, 'Inv', true)
    else
        set_hyperparams(params, 'PredictRewPrior', true)  -- 2nd param adds model approach to model name
    end
    --ACTIVATE_PREDICTIVE_PRIORS = false -- Momentaneous substitution of APPLY_REWARD_PREDICTION_CRITERION  TODO: replace when wokring by APPLY_REWARD_PREDICTION_CRITERION
    USE_CUDA = false --TODO for testing locally only


    print('cmd default params (overridden by following set_hyperparams): ')
    print(params)
    print_hyperparameters(true, 'predictive_priors_script.lua Hyperparams:')

    local records_paths = Get_Folders(DATA_FOLDER, 'record') --local list_folders_images, list_txt_action,list_txt_button, list_txt_state=Get_HeadCamera_View_Files(DATA_FOLDER)
    NB_SEQUENCES= #records_paths

    if DATA_FOLDER == COMPLEX_DATA then
       NB_SEQUENCES = NB_SEQUENCES - 1 -- Just because it is a dumb looking action without much action, we dont consider it
    end
    --Too much RAM needed: 24GB, freezes memory, and computer unusable for anyone
    -- if DATA_FOLDER == COLORFUL then  --USE COLORFUL75 INSTEAD FOR EFFICIENCY IN THE PIPELINE AND AVOID USING FULL DATASET REPRESENTATIONS STATES ETC IN IMAGEANDREPRTOTEXT.LUA
    --    NB_SEQUENCES = NB_SEQUENCES - 75 --To handle them in memory we start with 150-75 = 75
    -- end
    if NB_SEQUENCES ==0  then --or not folder_exists(DATA_FOLDER) then
        error('Error: data was not found in input directory INPUT_DIR= '.. DATA_FOLDER)
    end

    if LOGGING_ACTIONS then
       print("LOGGING ACTIONS")
       LOG_ACTION = {}

       for i=1,NB_SEQUENCES do
          LOG_ACTION[#LOG_ACTION+1] = {}
       end
    end

    ALL_SEQ = precompute_all_seq(NB_SEQUENCES)

    for nb_test=1, #PRIORS_CONFIGS_TO_APPLY do
       if RELOAD_MODEL then
          print("Reloading model in "..SAVED_MODEL_PATH)
          Model = torch.load(SAVED_MODEL_PATH):double()
       else
          print("Getting model in : "..MODEL_ARCHITECTURE_FILE)
          require('./models/full_inverse_model')  --    MODEL_ARCHITECTURE_FILE = INVERSE
          Model=getModel(DIMENSION_OUT, DIMENSION_ACTION)
          --graph.dot(Model.fg, 'Our Model')
       end

       if USE_CUDA then
          Model=Model:cuda()
       end

       parameters, gradParameters = Model:getParameters()
       -- In siamese networks we need one copy of the network per input (image) we want to compare at the same time, because otherwise,
       -- we could not compare results if we would otherwise have the same network being applied twice. Since the max number of different images
       -- we need for all priors is 4 (accounting for states and rewards in total (see priors formulas, Repeatability and proportionality need 4 images each), therefore, 4 clones of the network are enogh. I.e.
       -- we dont need one clone per prior, but one per different image we need to get data from to be compared in our priors)
       Model2=Model:clone('weight','bias','gradWeight','gradBias','running_mean','running_std')
       Model3=Model:clone('weight','bias','gradWeight','gradBias','running_mean','running_std')
       Model4=Model:clone('weight','bias','gradWeight','gradBias','running_mean','running_std')
       Models={Model1=Model,Model2=Model2,Model3=Model3,Model4=Model4}

       local priors_used = {FORWARD_MODEL}
       local Log_Folder=Get_Folder_Name(LOG_FOLDER, priors_used)

       print("Inverse model Experiment "..nb_test)-- .." (Log_Folder="..Log_Folder..")")
       train(Models, priors_used)
       print_hyperparameters(false, "Predictive priors Experiment run successfully for hyperparams: ")
    end

    if LOGGING_ACTIONS then
       print("LOG_ACTION")
       for key,items in ipairs(LOG_ACTION) do
          i = 0
          for k,j in pairs(items) do
             i = i+1
          end
          print(key,i)
       end
    end
end


local cmd = torch.CmdLine()
-- Basic options
cmd:option('-use_cuda', false, 'true to use GPU, false (default) for CPU only mode')
cmd:option('-use_continuous', false, 'true to use a continuous action space, false (default) for discrete one (0.5 range actions)')
cmd:option('-data_folder', MOBILE_ROBOT, 'Possible Datasets to use: staticButtonSimplest, mobileRobot, staticButtonSimplest, simpleData3D, pushingButton3DAugmented, babbling')
cmd:option('-mcd', 0.4, 'Max. cosine distance allowed among actions for priors loss function evaluation (MAX_COS_DIST_AMONG_ACTIONS_THRESHOLD)')
cmd:option('-sigma', 0.4, "Sigma: denominator in continuous actions' extra factor (CONTINUOUS_ACTION_SIGMA)")
cmd:option('-hidden_units', 5, "Num of hidden units in the inverse/forward model (NUM_HIDDEN_UNITS)")
--TODO Set best mcd and sigma after grid search

local params = cmd:parse(arg)  --TODO function to get all command line arguments that are the same right now for all Lua scripts, only in one function.
main(params)
