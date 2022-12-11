import { time, loadFixture } from '@nomicfoundation/hardhat-network-helpers';
import { anyValue } from '@nomicfoundation/hardhat-chai-matchers/withArgs';
import { expect } from 'chai';
import { ethers } from 'hardhat';
import { formatEther, parseEther } from 'ethers/lib/utils';
import { BigNumber } from 'ethers';

describe('Harberger', function () {
  async function deployAndDistributeFixture() {
    const [owner, ...otherAccounts] = await ethers.getSigners();

    const Harberger = await ethers.getContractFactory('MockHarberger', owner);
    const harberger = await Harberger.deploy();

    await Promise.all(
      otherAccounts.map(async (account, index) => {
        await harberger.send(account.address, index);
      })
    );

    return { harberger, owner, otherAccounts };
  }

  it('should change evaluation of token', async function () {
    const { harberger, owner, otherAccounts } = await loadFixture(deployAndDistributeFixture);

    const tokenId = parseEther('0');
    const newEvaluation = parseEther('1');

    await harberger.connect(otherAccounts[0]).selfEvaluate(tokenId, newEvaluation);

    expect(await harberger.getEvaluation(tokenId)).to.equal(newEvaluation);
  });

  it('Should increase owed tax', async function () {
    const { harberger, otherAccounts } = await loadFixture(deployAndDistributeFixture);

    const tokenId = parseEther('0');

    await harberger.connect(otherAccounts[0]).recalculateTax(tokenId);
    const tax0: BigNumber = await harberger.getTaxOwed(tokenId);

    await time.increase(time.duration.days(180));
    await harberger.connect(otherAccounts[0]).recalculateTax(tokenId);
    const tax1: BigNumber = await harberger.getTaxOwed(tokenId);

    // expect tax1 to be greater than tax0
    expect(tax1).to.be.gt(tax0);
  });
});
