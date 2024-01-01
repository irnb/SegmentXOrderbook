.PHONY: test anvil deploy install slither lint clean interact compile

anvil:
	@echo "Do you want to fork a chain? [yes/no]: "; \
	read fork_chain; \
	if [ $$fork_chain = "yes" ]; then \
		echo "Enter RPC URL: "; \
		read rpc_url; \
		echo "Enter Block Number: "; \
		read block_number; \
		echo "Running local network in fork mode..."; \
		anvil --fork-url $$rpc_url --fork-block-number $$block_number; \
	else \
		echo "Running simple local network..."; \
		anvil; \
	fi

test:
	@echo "Running smart contract tests with Foundry..."; \
	forge test -vvvv --gas-report;\

deploy:
	@echo "Enter the contract filename and contract name (e.g., MyContract.sol:MyContract): "; \
	read contract_name ; \
	echo "Do you want to deploy on localhost? [yes/no]: " ; \
	read deploy_local ; \
	if [ "$$deploy_local" = "yes" ]; then \
		echo "Please make sure you have a local network running on port 8545 (run 'make anvil' in a separate terminal)"; \
		echo "Enter the path to the constructor arguments file (e.g., ./.args): "; \
		read args_path; \
		echo "Enter your private key: "; \
		read private_key; \
		echo "Deploying on localhost"; \
		forge create src/$$contract_name --rpc-url http://localhost:8545 --private-key $$private_key --constructor-args-path $$args_path; \
	else \
		echo "Enter the RPC URL: "; \
		read rpc_url; \
		echo "Enter the Chain ID: "; \
		read chain_id; \
		echo "Enter your etherscan API key: "; \
		read etherscan_api_key; \
		echo "Enter the path to the constructor arguments file (e.g., ./args): "; \
		read args_path; \
		echo "Enter your private key: "; \
		read private_key; \
		echo "========================================================" >> deploy_history.txt; \
		echo "Deployment Date: `date` \n" >> deploy_history.txt; \
		echo "Deploying on a different network"; \
		forge create src/$$contract_name --rpc-url $$rpc_url  --private-key $$private_key --constructor-args-path $$args_path --etherscan-api-key $$etherscan_api_key --verify --chain-id $$chain_id | tee -a deploy_history.txt ;\
		echo "Constructor Arguments: " >> deploy_history.txt; \
		cat $$args_path >> deploy_history.txt; \
		echo "\nEnter the deployment note: "; \
		read deployment_details; \
		echo "\nDeployment Note: $$deployment_details" >> deploy_history.txt; \
	fi

install:
	@echo "Installing dependencies..."
	@echo "Installing forge..."
	forge install
	pip3 install slither-analyzer
	@echo "remeber to add your pip3 bin to your PATH "
	@echo "(add this line in your .zshrc or .bashrc `export PATH=$$PATH:~/Library/Python/3.9/bin`)"

slither:
	@echo "Running Slither..."
	slither ./src

lint:
	@echo "Formatting code..."
	forge fmt 

clean:
	@echo "Cleaning up..."
	forge clean

snapshot:
	@echo "Snapshot of gas usage";
	forge snapshot --diff --gas-report; 

interact:
	@echo "1- first deploy your contract";
	@echo "2- go to this websit https://eth95.dev/ "
	@echo "3- connect to your local network or to the network you deployed your contract on"
	@echo "4- input the contract address and the ABI"
	@echo "*** instead of above approach you can use the Rivet contract section too ***"
	@echo "you can find the ABI in the out directory"

compile:
	@echo "Compiling contracts..."
	forge compile