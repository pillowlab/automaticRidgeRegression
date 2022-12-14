function [kHat,hyperprs,CpriorInv] = autoSmoothRidgeRegress(dstruct,strtInds,opts,initprs)
% [kHat,hyperprs,CpriorInv] = autoCorrRidgeRegress(dstruct,strtInds,opts,initprs)
%
% Empirical Bayes "smooth ridge regression" using fixed point method.
%
% Computes ML estimate of the prior variance, exponential correlation
% falloff, and noise variance, and uses these to compute the MAP filter
% estimate
%
% Inputs:
%   dstruct = structure for raw correlations.  Fields are:
%       .xx = autocorrelation of stimulus:  (nx x nx) matrix
%       .xy = correlation between stimulus (input) and output: (nx x 1) vector
%       .yy = autocorrelation of output: (scalar)
%       .ny = number of output samples 
%   strtInds (optional) = indices in k at which new column starts 
%            (for multi-column filters )
%   opts (optional) = options stucture w/ fields: 
%             .maxiter, .tol, .maxalpha, .maxrho
%   prs0 (optional) = initial param struct, fields: .alpha, .rho, .nsevar
%
% Outputs:
%   kHat = empirical bayes estimate of kernel (under "ridge" prior).
%      given by: kHat = inv(dstruct.xx+CpriorInv*nsevar)*dstruct.xy;
%   hyperprs = estimated hyperparameters.
%       .alpha = precision (inverse variance)
%       .rho = exponential correlation space constant
%       .nsevar = noise variance 
%   CpriorInv = inverse of prior covariance matrix
%
% -----------------------
% Details:  the innverse prior covariance is given by
%
%   C^-1 = alpha/(1-rho^2)[ 1     -rho
%                         -rho  1 + rho^2 -rho
%                                  ....
%                                   -rho  1+rho^2 -rho
%                                          -rho     1]
%
% This produces a cov matrix w/ exponential falloff:
%    C(dt) = (1/alpha)*rho^(-|dt|) = (1/alpha) exp(dt*log(|dt|)).



% ---- Parse intputs ----
if nargin < 4, initprs=[]; end
if nargin < 3, opts=[]; end
if nargin < 2, strtInds=1; end

% ---- Set default options ----
if isempty(opts)
    opts.maxiter = 5000;  % max # iters
    opts.tol = 1e-5;    % stop if change in hyperparams less than this
    opts.maxalpha = 1e8; % alpha above which we shrink filter to all-zeros
    opts.maxrho = 1-1e-4; % maximum allowed correlation falloff (must be <=1)
end

% ---- Define matrices needed for inverse prior covariance ------
nx = size(dstruct.xx,1); % length of stimulus filter
Meye = speye(nx); % identity matrix
strtInds = strtInds(:);  % indices where columns of k start
endInds = [strtInds(2:end)-1;nx];  % indices where column of k end
allInds = [strtInds;endInds]; % all such indices
vecs  = ones(nx,3);  
vecs(allInds,1) = 0;
vecs(endInds,2) = 0;
vecs(strtInds,3) = 0;
Mdiag = spdiags(vecs(:,1), 0, nx, nx); % interior terms along diagonal
Moffdiag = spdiags(vecs(:,2:3), [-1 1],nx,nx);  % off-diagonal terms

% ---- Set default parameters ----
if isempty(initprs)
    % run ridge regression to estimate alpha0 and nsevar0
    fprintf('Initializing with standard ridge regression:\n');
    [~,hprs_ridge] = autoRidgeRegress_fixedpoint(dstruct, 1);
    alpha = hprs_ridge.alpha; % ridge parameter
    nsevar = hprs_ridge.nsevar; % output noise
    rho = .5;  % prior correlation
else
    alpha = initprs.alpha;
    rho = initprs.rho;
    nsevar = initprs.nsevar;
end

% --- initialize some params for iterative fixed-point algorithm -------
jcount = 1;      % counter for fixed-point algorithm
dparams = inf;   % change in params from previous step (initialize to inf)

% --- run fixed-point algorithm for maximizing marginal likelihood ------
while (jcount <= opts.maxiter) && (dparams>opts.tol) && (alpha < opts.maxalpha)
    
    % form prior covariance matrix
    CpriorInv = alpha*(Meye + rho^2*Mdiag - rho*Moffdiag)/(1-rho^2);

    % find mean and covariance of Gaussain posterior
    [mu,Lpost] = compGaussianPosterior(dstruct.xx,dstruct.xy,nsevar,CpriorInv); % compute posterior mean, cov
    
     % %---------- inspect evidence (for debugging) -----------------------
     % [jcount alpha rho]
     % logEv = nrmLogEvidence(CpriorInv,nsevar,dstruct.xx,dstruct.xy,dstruct.yy,dstruct.ny) % compute log-evidence
     % plot(1:nx,mu,'r'); drawnow; %pause;
     % %-------------------------------------------------------------------
    
    % update values of alpha and rho
    [alpha2,rho2] = updateCovPrs(mu,Lpost,opts.maxrho,Mdiag,Moffdiag); 
    % update value of nsevar
    resids = (dstruct.yy  -  2*mu'*dstruct.xy  +  mu'*dstruct.xx*mu); % total residual error        
    traceTrm = trace(Lpost*CpriorInv); % trace of Lpost*CpriorInv
    nsevar2 = resids./(dstruct.ny-(nx-traceTrm)*1);  % correct update rule shold have "*1"
        
    % update counter, alpha & nsevar
    dparams = norm([alpha2;rho2;nsevar2]-[alpha;rho;nsevar]);
    jcount = jcount+1;
    alpha = alpha2;
    rho = rho2;
    nsevar = nsevar2;
        
end

% check convergence
if alpha >= opts.maxalpha
    fprintf('autoCorrRidgeRegress: precision alpha=inf; filter is all-zeros (#%d steps)\n', jcount);
elseif jcount < opts.maxiter
    fprintf('autoCorrRidgeRegress: finished EB ridge regression in #%d steps\n', jcount)
else
    fprintf('autoCorrRidgeRegress: MAXITER (%d) steps; dparams=%f\n', jcount, dparams);
end

kHat = compGaussianPosterior(dstruct.xx,dstruct.xy,nsevar,CpriorInv); % compute MAP estimate for k
hyperprs.alpha = alpha;
hyperprs.rho = rho;
hyperprs.nsevar = nsevar;

% ============================================================
function [mu,L] = compGaussianPosterior(xx,xy,nsevar,CpriorInv)
% [mu,L] = compGaussianPosterior(xx,xy,nsevar,CpriorInv)
%
% Compute posterior mean and covariance given observed data Y given X, 
% (Or, given dstruct.xx = X'*X; xy = X'*Y) and with
% noise variance nsevar and prior inverse-covariance CpriorInv

mu = (xx+nsevar*CpriorInv)\xy;
if nargout > 1
    L = inv(xx./nsevar + CpriorInv);  % covariance
end


% ============================================================
function [alpha,rho] = updateCovPrs(x,Lpost,MAXRHO,Mdiag,Moffdiag)
% estimate alpha and rho from the current mean 
%
% (note: this is an approximate update)

nx = length(x);
aa = nx./(nx-1);  % a constant we need

% Three terms we need
A = sum(x.^2)+sum(diag(Lpost));  % full diagonal terms
B = x'*Mdiag*x + trace(Mdiag.*Lpost); % other diagonal terms
C = .5*( x'*Moffdiag*x + sum(sum(Moffdiag.*Lpost))); % off-diag terms

% Solve cubic equation for rho 
coeffs = [-B, (2-aa)*C, (aa-1)*A+aa*B, -aa*C];
rho = roots(coeffs);  % solve polynomial
rho = rho((imag(rho)==0));  % keep only real-valued roots

% if three real roots, take middle one
if length(rho)>1
    rho = median(rho);
end
rho = min(max(rho,0),MAXRHO);  % bound above 0 and below MAXRHO

% Solve for alpha (precision)
alpha = nx*(1-rho.^2)/(A+rho^2*B-2*rho*C);
