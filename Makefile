# include .env file and export its env vars
# (-include to ignore error if it does not exist)
-include .env

all: clean install update build

# Install proper solc version.
solc:; nix-env -f https://github.com/dapphub/dapptools/archive/master.tar.gz -iA solc-static-versions.solc_0_8_13

# Clean the repo
clean  :; forge clean

# Install the Modules
install :; forge install

# Update Dependencies
update:; forge update

# Builds
build  :; forge build

# chmod scripts
scripts :; chmod +x ./scripts/*


# deployment scripts
run-optimism-test :; forge script --rpc-url https://kovan.optimism.io \
	scripts/DeployXChain.s.sol:XChainHubOptimism \
	--private-key ${PRIVATE_KEY} \
	-vvvv


run-optimism-real :; forge script --rpc-url https://optimism-kovan.infura.io/v3/${INFURA_KEY} \
	scripts/DeployXChain.s.sol:XChainHubOptimism \
	--private-key ${PRIVATE_KEY} \
	--broadcast \
	-vvvv


# Deploy the xchain contract - kovan opt
deploy-kovan-opt :; forge create --rpc-url https://optimism-kovan.infura.io/v3/${INFURA_KEY} \
    --constructor-args "0xCC68641528B948642bDE1729805d6cf1DECB0B00" "0x72aB53a133b27Fa428ca7Dc263080807AfEc91b5" "0x63BCe354DBA7d6270Cb34dAA46B869892AbB3A79" \
    --private-key ${PRIVATE_KEY} src/XChainStargateHub.sol:XChainStargateHub \
    --etherscan-api-key ${ETHERSCAN_API_KEY_KOVAN_OPTIMISM} \
    --verify

# Deploy the xchain contract - arbi rink
deploy-arbitrum-rink :; forge create --rpc-url https://rinkeby.arbitrum.io/rpc \
    --constructor-args "0x6701D9802aDF674E524053bd44AA83ef253efc41" "0x4D747149A57923Beb89f22E6B7B97f7D8c087A00" "0x63BCe354DBA7d6270Cb34dAA46B869892AbB3A79" \
    --private-key ${PRIVATE_KEY} src/XChainStargateHub.sol:XChainStargateHub \
    --etherscan-api-key ${ETHERSCAN_API_KEY_ARBITRUM_RINKEBY} \
    --verify

# Deploy the xchain strategy - kovan opt
deploy-strat-kovan-opt :; forge create --rpc-url https://kovan.optimism.io \
    --constructor-args "0x68d5e0e257541180f60273c5e44a179c12ae9280" "0xaf29ba76af7ef547b867eba712a776c61b40ed02" "0x567f39d9e6d02078F357658f498F80eF087059aa" "0x63BCe354DBA7d6270Cb34dAA46B869892AbB3A79" "0x63BCe354DBA7d6270Cb34dAA46B869892AbB3A79" "Test Strategy" \
    --private-key ${PRIVATE_KEY} src/strategy/XChainStrategyStargate.sol:XChainStrategyStargate \
    --etherscan-api-key ${ETHERSCAN_API_KEY_KOVAN_OPTIMISM} \
    --verify

# Deploy the xchain contract - arbi rink
deploy-strat-arbitrum-rink :; forge create --rpc-url https://rinkeby.arbitrum.io/rpc \
    --constructor-args "0xfa0299ef90f0351918ecdc8f091053335dcfb8c9" "0x2e05590c1b24469eaef2b29c6c7109b507ec2544" "0x1EA8Fb2F671620767f41559b663b86B1365BBc3d" "0x63BCe354DBA7d6270Cb34dAA46B869892AbB3A79" "0x63BCe354DBA7d6270Cb34dAA46B869892AbB3A79" "Test Strategy" \
    --private-key ${PRIVATE_KEY} src/strategy/XChainStrategyStargate.sol:XChainStrategyStargate \
    --etherscan-api-key ${ETHERSCAN_API_KEY_ARBITRUM_RINKEBY} \
    --verify

# run script


# env var check
check-env :; echo $(PRIVATE_KEY)


