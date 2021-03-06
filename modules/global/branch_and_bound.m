function [x_min,solved_nodes,lower,upper,lower_hist,upper_hist,timing,counter,problem] = branch_and_bound(p,x_min,upper,timing)

% *************************************************************************
% Initialize diagnostic code
% *************************************************************************
problem = 0;

% *************************************************************************
% Create handles to solvers
% *************************************************************************
lowersolver = p.solver.lowersolver.call; % For relaxed lower bound problem
uppersolver = p.solver.uppersolver.call; % Local nonlinear upper bound
lpsolver    = p.solver.lpsolver.call;    % LP solver for bound propagation

% *************************************************************************
% GLOBAL PROBLEM DATA (these variables are the same in all nodes)
% *************************************************************************
c       = p.c;
Q       = p.Q;
f       = p.f;
K       = p.K;
options = p.options;

% *************************************************************************
% After initial bound propagation, can convexity etc be fixed?
% *************************************************************************
p = fixOperatorProperties(p);

% *************************************************************************
% DEFINE UPPER BOUND PROBLEM. Basically just remove the cuts
% *************************************************************************
p_upper = cleanuppermodel(p);
p_upper = compile_nonlinear_table(p_upper);
p_upper = compile_bilinearslist(p_upper);
p_upper = compile_quadraticslist(p_upper);

% *************************************************************************
% Add constraints obtained from multiplying linear constraints with 
% variables leading to bilinear constraints with monomials already used
% *************************************************************************
if p.options.bmibnb.cut.multipliedequality
    p = addMultipliedEqualityCuts(p);
end
if p.options.bmibnb.cut.multipliedinequality
    p = addMultipliedInequalityCuts(p);
end

% *************************************************************************
% Active constraints in main model
% 0   : Inactive constraint (i.e. a cut which unused)
% 1   : Active constraint
% inf : Removed constraint  (found to be redundant)
% *************************************************************************
p.InequalityConstraintState = ones(p.K.l,1);
p.InequalityConstraintState(p.KCut.l,1) = 0;
p.EqualityConstraintState = ones(p.K.f,1);

% *************************************************************************
% LPs ARE USED IN  BOX-REDUCTION
% *************************************************************************
p.lpcuts = p.F_struc(1+p.K.f:1:p.K.l+p.K.f,:);
p.cutState = ones(p.K.l,1);
p.cutState(p.KCut.l,1) = 0; % Don't use to begin with

% *************************************************************************
% INITIALITAZION
% *************************************************************************
p.depth = 0;        % depth in search tree
p.dpos  = 0;        % used for debugging
p.lower = NaN;
p.spliton = [];
lower   = NaN;
gap     = inf;
stack   = [];
solved_nodes = 0;
numGlobalSolutions = 0;

% *************************************************************************
% Silly hack to speed up solver calls
% *************************************************************************
p.getsolvertime = 0;

counter = p.counter;

if options.bmibnb.verbose>0    
    k = nnz(isinf(p.lb(p.branch_variables)));
    if k>0   
        if k == 1
            disp(['* Warning: ' num2str(k) ' branch variable is unbounded from below']);
        else
            disp(['* Warning: ' num2str(k) ' branch variables are unbounded from below']);
        end
    end
    k = nnz(isinf(p.ub(p.branch_variables)));
    if k>0
        if k == 1
            disp(['* Warning: ' num2str(k) ' branch variable is unbounded from above']);
        else
            disp(['* Warning: ' num2str(k) ' branch variables are unbounded from above']);
        end
    end    
    disp('* Starting the b&b process');
    disp(' Node       Upper      Gap(%)       Lower    Open   Time');
end

t_start = cputime;
go_on  = 1;

lower_hist = [];
upper_hist = [];
p.branchwidth = [];

% Create a default propagator structure
propagator.fun = [];
propagator.time = [];
propagator.reduction = [];
propagator.worked = [];
% Define all available bound propagation strageies
propagators{1} = propagator;propagators{1}.fun = @propagate_bounds_from_complete_nested_evaluation;
propagators{2} = propagator;propagators{2}.fun = @propagate_bounds_from_upper;
propagators{3} = propagator;propagators{3}.fun = @propagate_bounds_from_arbitrary_quadratics;
propagators{4} = propagator;propagators{4}.fun = @propagate_bounds_from_complementary;
propagators{5} = propagator;propagators{5}.fun = @propagate_bounds_lp;
propagators{6} = propagator;propagators{6}.fun = @propagate_bounds_from_equalities;
propagators{7} = propagator;propagators{7}.fun = @propagate_bounds_from_combinatorics;
propagators{8} = propagator;propagators{8}.fun = @propagate_bounds_from_separable_quadratic_equality;

while go_on
    
    % *********************************************************************
    % ASSUME THAT WE WON'T FATHOME
    % *********************************************************************
    keep_digging = 1;
    info_text = '';
    
    % *********************************************************************
    % Strenghten variable bounds a couple of runs
    % *********************************************************************
    p.changedbounds = 1;
    time_ok = 1;
    
    p.upper = upper;   
    for i = 1:length(options.bmibnb.strengthscheme)
        p = adjustMaxTime(p,p.options.bmibnb.maxtime,cputime-t_start);
        time_ok = cputime-t_start < options.bmibnb.maxtime;
        if ~p.feasible | ~time_ok
            break
        end
        j = options.bmibnb.strengthscheme(i); 
        if j == 5
            % Special case, clean up to remove
            LU=[p.lb p.ub];
            [volBefore,openVariables] = branchVolume(p);
            propagators{j}.time(end+1) = tic;
            tstart = tic;
            [p,~,~,seen_x] = propagate_bounds_lp(p,upper,lower,lpsolver,x_min);
            timing.lpsolve = timing.lpsolve + toc(tstart);
            propagators{j}.time(end) = toc(uint64(propagators{j}.time(end)));
            volAfter = branchVolume(p,openVariables);
            propagators{j}.reduction(end+1) = (volBefore-volAfter)/volAfter;            
            X = [seen_x{:}];
            X = unique(X','rows')';
            tstart = tic;
            for k = 1:size(X,2)                
                [upper,x_min,~,info_text_temp,numGlobalSolutions] = heuristics_from_relaxed(p_upper,X(:,k),upper,x_min,inf,numGlobalSolutions);                                
                if length(info_text_temp) > 0
                    info_text = info_text_temp;
                end                    
            end                        
            p.counter.heuristics = p.counter.heuristics + size(X,2);
            timing.heuristics = timing.heuristics + toc(tstart);
            propagators{j}.worked  = [propagators{j}.worked sparse([LU(:,1)~=p.lb | LU(:,2)~=p.ub])];          
            if upper < p.upper 
                p.upper = upper;
                p = propagate_bounds_from_upper(p,upper);
            else
                p.upper = upper;
            end
        else
            LU=[p.lb p.ub];
            [volBefore,openVariables] = branchVolume(p);
            propagators{j}.time(end+1) = tic;
            p = feval(propagators{j}.fun,p);
            propagators{j}.time(end) = toc(uint64(propagators{j}.time(end)));
            volAfter = branchVolume(p,openVariables);
            propagators{j}.reduction(end+1) = (volBefore-volAfter)/volAfter;     
            propagators{j}.worked  = [propagators{j}.worked [LU(:,1)~=p.lb | LU(:,2)~=p.ub]];                         
        end 
        if ~p.feasible | ~time_ok
            break
        end
    end

    % *********************************************************************
    % SOLVE LOWER AND UPPER
    % *********************************************************************
    if ~time_ok
        info_text = 'Time-out during bound-propagation';
        keep_digging = 0; 
        cost = inf;
    elseif p.feasible
        
        % *********************************************************************
        % Detect redundant constraints
        % *********************************************************************
        p = remove_redundant(p);
        p = adjustMaxTime(p,p.options.bmibnb.maxtime,cputime-t_start);
        [output,cost,p,timing] = solvelower(p,options,lowersolver,x_min,upper,timing);

        if output.problem == -1
            % We have no idea what happened. 
            % Behave as if it worked, so we can branch as see if things
            % clean up nicely
            cost = p.lower;
            if isnan(cost)
                cost = -inf;
            end
            output.problem = 3;
        end
        
        % Some solvers cannot differentiate unbounded and infeasible
        if output.problem == 12
            pp = p;
            pp.c = pp.c*0;
            [output2,cost2] = solvelower(pp,options,lowersolver,[],[],timing);
            if output2.problem == 0
                output.problem = 2;
            else
                output.problem = 1;
            end
        end
                       
        switch output.problem
            case 1 % Infeasible
                 if length(info_text)==0
                    info_text = 'Infeasible node in lower solver';
                 else
                    info_text = [info_text ' | ' 'Infeasible node in lower solver'];                    
                 end                                        
                keep_digging = 0;
                cost = inf;
                feasible = 0;

            case {0,2,3,4} % (disregard numerical problems)

                % Unbounded
                if output.problem == 2
                    cost = -inf;
                end
                
                if (output.problem == 3) | (output.problem == 4)
                    info_text = 'Numerical problems in lower solver';
                end
                x = output.Primal;
                
                % UPDATE THE LOWER BOUND
                if isnan(lower)
                    lower = cost;
                end
                if ~isempty(stack)
                    lower = min(cost,min([stack.lower]));
                else
                    lower = min(lower,cost);
                end

                relgap = 100*(upper-lower)/(1+abs(upper));
                relgap_too_big = (isinf(lower) | isnan(relgap) | relgap>options.bmibnb.relgaptol);
                if cost<upper-1e-5 & relgap_too_big

                    z = evaluate_nonlinear(p,x);

                    % Manage cuts etc
                    p = createsdpcut(p,z);
                    p = addlpcuts(p,x);

                    oldCount = numGlobalSolutions;
                    if numGlobalSolutions < p.options.bmibnb.numglobal   
                        tstart = tic;
                        [upper,x_min,cost,info_text2,numGlobalSolutions] = heuristics_from_relaxed(p_upper,x,upper,x_min,cost,numGlobalSolutions);
                        timing.heuristics = timing.heuristics + toc(tstart);
                        
                        p.counter.heuristics = p.counter.heuristics + 1;
                        if length(info_text)==0 &&  length(info_text2)>0
                            info_text = info_text2;
                        elseif  length(info_text2)>0 && ~isequal(info_text,info_text2)
                            info_text = [info_text ' | ' info_text2];                       
                        end
                        if ~isequal(p.solver.uppersolver.tag,'none') & ~p.options.bmibnb.onlyrunupperinroot
                            if upper > p.options.bmibnb.target
                                if options.bmibnb.lowertarget > lower                                    
                                    [upper,x_min,info_text,numGlobalSolutions,timing,p_upper] = solve_upper_in_node(p,p_upper,x,upper,x_min,uppersolver,info_text,numGlobalSolutions,timing,p.options.bmibnb.uppersdprelax);
                                    p.counter.uppersolved = p.counter.uppersolved + 1;
                                end
                            end
                        end
                        if upper < p.upper                              
                            p = propagate_bounds_from_upper(p,upper);
                        end
                    end
                else
                    keep_digging = 0;
                    info_text = 'Poor bound in lower, killing node';
                end
            otherwise
                cost = lower;
                x = (p.lb+p.ub)/2;
        end
    else
        info_text = 'Infeasible in node bound-propagation';
        keep_digging = 0;
        cost = inf;
        feasible = 0;
    end
    solved_nodes = solved_nodes+1;

    % ************************************************
    % PRUNE SUBOPTIMAL REGIONS BASED ON UPPER BOUND
    % ************************************************
    if ~isempty(stack)
        nodesBefore = length(stack);
        [stack,lower] = prune(stack,upper,options,solved_nodes,p);
        nodesAfter = length(stack);
        if nodesBefore > nodesAfter
            if length(info_text)==0
                info_text = 'Pruned stack based on new upper bound';
            else
                info_text = [info_text ' | ' 'Pruned stack based on new upper bound'];
            end
        end
    end
    if isempty(stack)
        if isinf(cost) && (cost > 0)
            lower = upper;
        elseif cost > upper
            lower = upper;
        else
            lower = cost;
        end
    else
        lower = min(lower,cost);
    end

    % ************************************************
    % CONTINUE SPLITTING?
    % ************************************************
    if ~isempty(p.branch_variables) && keep_digging && max(p.ub(p.branch_variables)-p.lb(p.branch_variables))>options.bmibnb.vartol && upper > lower
        node = [];
        spliton = branchvariable(p,options,x);      
        if ismember(spliton,p.complementary)
            i = find(p.complementary(:,1) == spliton);
            if isempty(i)
                i = find(p.complementary(:,2) == spliton);
            end
            % Either v1 or v2 is zero
            v1 = p.complementary(i,1);
            v2 = p.complementary(i,2);
            gap_over_v1 = (p.lb(v1)<=0) & (p.ub(v1)>=0) & (p.ub(v1)-p.lb(v2))>0;
            gap_over_v2 = (p.lb(v2)<=0) & (p.ub(v2)>=0) & (p.ub(v2)-p.lb(v2))>0;
            
            if gap_over_v1
                pp = p;
                pp.complementary( find((pp.complementary(:,1)==v1) | (pp.complementary(:,2)==v1)),:)=[];
                node = savetonode(pp,v1,0,0,-1,x,cost,p.EqualityConstraintState,p.InequalityConstraintState,p.cutState);
                node.bilinears = p.bilinears;
                node = updateonenonlinearbound(node,spliton);
                if all(node.lb <= node.ub)
                    node.branchwidth=[];
                    stack = push(stack,node);                 
                end
            end
            if gap_over_v2
                pp = p;
                %pp.complementary(i,:)=[];
                pp.complementary( find((pp.complementary(:,1)==v2) | (pp.complementary(:,2)==v2)),:)=[];
                node = savetonode(pp,v2,0,0,-1,x,cost,p.EqualityConstraintState,p.InequalityConstraintState,p.cutState);
                node.bilinears = p.bilinears;
                node = updateonenonlinearbound(node,spliton);
                if all(node.lb <= node.ub)
                    node.branchwidth=[];
                    stack = push(stack,node);                 
                end
            end     
        end
        if isempty(node)
            if ismember(spliton,union(p.binary_variables,p.integer_variables)) 
                node1 = savetonode(p,spliton,p.lb(spliton),floor(x(spliton)),-1,x,cost,p.EqualityConstraintState,p.InequalityConstraintState,p.cutState);
                node2 = savetonode(p,spliton,ceil(x(spliton)),p.ub(spliton),-1,x,cost,p.EqualityConstraintState,p.InequalityConstraintState,p.cutState);
                node1.bilinears = p.bilinears;
                node1 = updateonenonlinearbound(node1,spliton);
                node1.branchwidth = [p.ub(spliton)-p.lb(spliton)];
                if all(node1.lb <= node1.ub)
                    stack = push(stack,node1);
                end
                node2.bilinears = p.bilinears;
                node2 = updateonenonlinearbound(node2,spliton);
                node2.branchwidth = [p.ub(spliton)-p.lb(spliton)];
                if all(node2.lb <= node2.ub)
                    stack = push(stack,node2);
                end
            else
                bounds  = partition(p,options,spliton,x);           
                for i = 1:length(bounds)-1                 
                    node = savetonode(p,spliton,bounds(i),bounds(i+1),-1,x,cost,p.EqualityConstraintState,p.InequalityConstraintState,p.cutState);                    
                    node.bilinears = p.bilinears;
                    node = updateonenonlinearbound(node,spliton);
                    node.branchwidth = [p.ub(spliton)-p.lb(spliton)];
                    if all(node.lb <= node.ub)
                        stack = push(stack,node);
                    end
                end
            end
        end
        if ~isempty(stack)
            lower = min([stack.lower]);
        end
    end

    if ~isempty(p)
        counter = p.counter;
    end
    % ************************************************
    %  Pick and create a suitable node
    % ************************************************    
    [p,stack] = selectbranch(p,options,stack,x_min,upper);
    
    if isempty(p)
        if ~isinf(upper)
            relgap = 0;
        end
        if isinf(upper) & isinf(lower)
            relgap = inf;
        end
        depth = 0;
    else
        relgap = 100*(upper-lower)/(1+max(abs(lower)+abs(upper))/2);
        depth = p.depth;
    end
    if options.bmibnb.verbose>0
        fprintf(' %4.0f : %12.3E  %7.2f   %12.3E   %2.0f   %3.0fs  %s  \n',solved_nodes,upper,relgap,lower,length(stack)+length(p),floor(cputime-t_start),info_text);
    end
    
    absgap = upper-lower;
    % ************************************************
    % Continue?
    % ************************************************
    time_ok = cputime-t_start < options.bmibnb.maxtime;
    iter_ok = solved_nodes < options.bmibnb.maxiter;
    any_nodes = ~isempty(p);
    relgap_too_big = (isinf(lower) | isnan(relgap) | relgap>100*options.bmibnb.relgaptol);
    absgap_too_big = (isinf(lower) | isnan(absgap) | absgap>options.bmibnb.absgaptol);
    uppertarget_not_met = upper > options.bmibnb.target;
    lowertarget_not_met = lower < options.bmibnb.lowertarget;
    go_on = uppertarget_not_met & lowertarget_not_met & time_ok & any_nodes & iter_ok & relgap_too_big & absgap_too_big;
    lower_hist = [lower_hist lower];
    upper_hist = [upper_hist upper];
end

if options.bmibnb.verbose>0   
    fprintf(['* Finished.  Cost: ' num2str(upper) ' Gap: ' num2str(relgap) '%%\n']);
    if ~time_ok
        fprintf(['* Termination due to time limit \n']);
    elseif ~iter_ok
        fprintf(['* Termination due to iteration limit \n']);
    elseif ~any_nodes
        fprintf(['* Termination with all nodes pruned \n']);
    elseif ~relgap_too_big
        fprintf(['* Termination with relative gap satisfied \n']);
    elseif ~absgap_too_big
        fprintf(['* Termination with relative gap satisfied \n']);
    elseif uppertarget_not_met
        fprintf(['* Termination with upper bound limit reached \n']);
    elseif uppertarget_not_met
        fprintf(['* Termination with upper bound target reached \n']);
    elseif lowertarget_not_met
        fprintf(['* Termination with lower bound target reached \n']);
    end
end

if ~time_ok || ~iter_ok
    problem = 3;
end

% *************************************************************************
% Stack functionality
% *************************************************************************
function stack = push(stackin,p)
if ~isempty(stackin)
    stack = [p;stackin];
else
    stack(1)=p;
end

function [p,stack] = pull(stack,method,x_min,upper,branch_variables);
if ~isempty(stack)
    switch method
        case 'maxvol'
            for i = 1:length(stack)
                vol(i) = sum(stack(i).ub(branch_variables)-stack(i).lb(branch_variables));
            end
            [i,j] = max(vol);
            p=stack(j);
            stack = stack([1:1:j-1 j+1:1:end]);

        case 'best'
            [i,j]=min([stack.lower]);
            p=stack(j);
            stack = stack([1:1:j-1 j+1:1:end]);

        otherwise
    end
else
    p =[];
end

function [stack,lower] = prune(stack,upper,options,solved_nodes,p)
if ~isempty(stack)
    toolarge = find([stack.lower]>upper*(1+1e-4));
    if ~isempty(toolarge)
        stack(toolarge)=[];
    end
    if ~isempty(stack)
        
        for j = 1:length(stack)
            if nnz(p.c.*(stack(j).ub-stack(j).lb)) == 1 & nnz(p.Q)==0
                i = find(p.c.*(stack(j).ub-stack(j).lb));
                if p.c(i)>0
                    stack(j).ub(i) = min([stack(j).ub(i) upper]);
                end
            end
        end
        
        indPOS = find(p.c>0);
        indNEG = find(p.c<0);
        LB = [stack.lb];
        UB = [stack.ub];
        LOWER =  p.c([indPOS(:);indNEG(:)])'*[LB(indPOS,:);UB(indNEG,:)];
        toolarge = find(LOWER > upper*(1-1e-8));
        stack(toolarge)=[];
    end
end
if ~isempty(stack)
    lower = min([stack.lower]);
else
    lower = upper;
end

function node = savetonode(p,spliton,bounds1,bounds2,direction,x,cost,EqualityConstraintState,InequalityConstraintState,cutState);
node.lb = p.lb;
node.ub = p.ub;
node.lb(spliton) = bounds1;
node.ub(spliton) = bounds2;
node.lb(p.integer_variables) = ceil(node.lb(p.integer_variables));
node.ub(p.integer_variables) = floor(node.ub(p.integer_variables));
node.lb(p.binary_variables) = ceil(node.lb(p.binary_variables));
node.ub(p.binary_variables) = floor(node.ub(p.binary_variables));
node.complementary = p.complementary;

if direction == -1
    node.dpos = p.dpos-1/(2^sqrt(p.depth));
else
    node.dpos = p.dpos+1/(2^sqrt(p.depth));
end
node.spliton = spliton;
node.depth = p.depth+1;
node.x0 = x;
node.lpcuts = p.lpcuts;
node.lower = cost;
node.InequalityConstraintState = InequalityConstraintState;
node.EqualityConstraintState = EqualityConstraintState;
node.cutState = cutState;

function p = addlpcuts(p,z)
if ~isempty(p.lpcuts)
    inactiveCuts = find(~p.cutState);
    violation = p.lpcuts(inactiveCuts,:)*[1;z];
    need_to_add = find(violation < -1e-4);
    if ~isempty(need_to_add)
        p.cutState(inactiveCuts(need_to_add)) = 1;
    end
    inactiveCuts = find(p.InequalityConstraintState == 0 );
    violation = p.F_struc(p.K.f+inactiveCuts,:)*[1;z];
    need_to_add = find(violation < -1e-4);
    if ~isempty(need_to_add)
        p.InequalityConstraintState(inactiveCuts(need_to_add)) = 1;
    end
end

% *************************************************************************
% Strategy for deciding which variable to branch on
% *************************************************************************
function spliton = branchvariable(p,options,x)
% Split if box is too narrow
width = abs(p.ub(p.branch_variables)-p.lb(p.branch_variables));
if isempty(p.bilinears) | ~isempty(p.evalMap) | any(p.variabletype > 2)%(min(width)/max(width) < 0.1) | (size(p.bilinears,1)==0) %
    [i,j] = max(width);
    spliton = p.branch_variables(j);
    if ~isempty(p.spliton) & p.spliton == spliton
        all_candidates = find(width == width(j));
        if length(all_candidates)>1
            spliton = p.branch_variables(all_candidates(2));
        end
    end
else
    res = x(p.bilinears(:,1))-x(p.bilinears(:,2)).*x(p.bilinears(:,3));
    if all(res == 0)
        % Can happen if lower bound computation failed.  
        if isempty(p.spliton)
            spliton = p.branch_variables(1);
            return
        else
            j = find(p.spliton == p.branch_variables);
            if j == length(p.branch_variables)
                spliton = p.branch_variables(1);
            else
                spliton = p.branch_variables(j+1);
            end
            return
        end
    end
    [ii,jj] = sort(abs(res));
    v1 = p.bilinears(jj(end),2);
    v2 = p.bilinears(jj(end),3);

    acc_res1 = sum(abs(res(find((p.bilinears(:,2)==v1) |  p.bilinears(:,3)==v1))));
    acc_res2 = sum(abs(res(find((p.bilinears(:,2)==v2) |  p.bilinears(:,3)==v2))));
    
    if abs(acc_res1-acc_res2)<1e-3 & ismember(v2,p.branch_variables) & ismember(v1,p.branch_variables)
        if abs(p.ub(v1)-p.lb(v1))>abs(p.ub(v2)-p.lb(v2))
            spliton = v1;
        elseif abs(p.ub(v1)-p.lb(v1))<abs(p.ub(v2)-p.lb(v2))
            spliton = v2;
        else
            spliton = v1;
        end
    else
        if (~ismember(v2,p.branch_variables) | (acc_res1>acc_res2)) & ismember(v1,p.branch_variables)
            spliton = v1;
        elseif ismember(v2,p.branch_variables)
            spliton = v2;
        else
            [i,j] = max(width);
            spliton = p.branch_variables(j);
        end
    end
end

% *************************************************************************
% Strategy for diving the search space
% *************************************************************************
function bounds = partition(p,options,spliton,x_min)
x = x_min;

for i = 1:length(p.evalMap)
    if ~isempty(p.evalMap{i}.properties.singularity)
        if isequal(spliton, p.evalMap{i}.variableIndex)
            if (p.evalMap{i}.properties.singularity > p.lb(spliton)) && (p.evalMap{i}.properties.singularity < p.ub(spliton))
                bounds = [p.lb(spliton) p.evalMap{i}.properties.singularity p.ub(spliton)];
                return
            end
        end
    end
    if ~isempty(p.evalMap{i}.properties.inflection)
        if isequal(spliton, p.evalMap{i}.variableIndex)
            for k = 1:length(p.evalMap{i}.properties.inflection)/2
                if (p.evalMap{i}.properties.inflection(2*k) > p.lb(spliton)) && (p.evalMap{i}.properties.inflection(2*k) < p.ub(spliton))
                    bounds = [p.lb(spliton) p.evalMap{i}.properties.inflection(1) p.ub(spliton)];
                    return
                end
            end
        end
    end
end
switch options.bmibnb.branchrule
    case 'omega'
        U = p.ub(spliton);
        L = p.lb(spliton);
        if isinf(L) | isinf(U)
            Ltemp = max(min(-1,x(spliton)-1),L);
            Utemp = min(max(1,x(spliton)+1),U);
            bounds = [L (Ltemp + Utemp)/2 U];             
        elseif ~isempty(x_min)
            x = x(spliton);
            bounds = [L 0.5*max(L,min(x_min(spliton),U))+0.5*(L+U)/2 U];            
        else
            bounds = [L (L+U)/2 U];
        end
    case 'bisect'
        bounds = [p.lb(spliton) (p.lb(spliton)+p.ub(spliton))/2 p.ub(spliton)];
    otherwise
        bounds = [p.lb(spliton) (p.lb(spliton)+p.ub(spliton))/2 p.ub(spliton)];
end
if isnan(bounds(2)) %FIX
    if isinf(p.lb(spliton))
        p.lb(spliton) = -1e6;
    end
    if isinf(p.ub(spliton))
        p.ub(spliton) = 1e6;
    end
    bounds(2) = (p.lb(spliton)+p.ub(spliton))/2;
end

function [p,stack] = selectbranch(p,options,stack,x_min,upper,cost_improvements)
switch options.bmibnb.branchmethod
    case 'maxvol'
        [node,stack] = pull(stack,'maxvol',x_min,upper,p.branch_variables);
    case 'best'
        [node,stack] = pull(stack,'best',x_min,upper);
    case 'best-estimate'
        [node,stack] = pull(stack,'best-estimate',x_min,upper,[],cost_improvements);

    otherwise
        [node,stack] = pull(stack,'best',x_min,upper);
end
% Copy node data to p
if isempty(node)
    p = [];
else
    p.depth = node.depth;
    p.dpos = node.dpos;
    p.spliton = node.spliton;
    p.lb = node.lb;
    p.ub = node.ub;
    p.lower = node.lower;
    p.lpcuts = node.lpcuts;
    p.x0 = node.x0;
    p.InequalityConstraintState = node.InequalityConstraintState;
    p.EqualityConstraintState = node.EqualityConstraintState;
    p.complementary = node.complementary;
    p.cutState = node.cutState;
    p.feasible = 1;
    p.branchwidth = node.branchwidth;
end