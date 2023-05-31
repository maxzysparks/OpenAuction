module.exports = async ({ getNamedAccounts, deployments }) => {
  const { deploy } = deployments;
  const { deployer } = await getNamedAccounts();

  // Determine the necessary constructor arguments for the OpenAuction contract and pass them here
  const constructorArgs = [
    // Replace arg1 and arg2 with the appropriate values
    3600, // Example value for arg1: 1 hour (in seconds)
    100,  // Example value for arg2: 100 wei
  ];

  await deploy("OpenAuction", {
    from: deployer,
    args: constructorArgs,
    log: true,
  });
};

module.exports.tags = ["OpenAuction"];
