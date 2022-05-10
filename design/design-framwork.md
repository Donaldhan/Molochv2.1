# 引言

# 合约架构

![molochv2-contract-framework](/image/molochv2/molochv2-contract-framework.png)

CloneFactory：基于EIP-1167合约clone工厂
Moloch：提案管理，包括创建，投票，处理，怒退，怒踢等流程；
MolochSummoner：创建DAO，注册DAO




DAO合约Moloch
主要管理提案，包括创建，投票，处理，怒退，怒踢等流程；


提案类型：正常提案；白名单提案；踢出提案；
股份类型：投票份额share，loot份额（无投票权限，怒退，被怒踢时，可以获得相应公会token的占比份额）



部署DAO合约Moloch，需要提供的信息如下：
* 初始化提案发起间隔
* 提案投票期限
* 提案公示缓冲期（此期间对结果不满意的人都可以怒退）
* 初始化成员及投票份额share
* 允许使用的token（DAO组织允许使用的token）
* 处理提案奖励ETH数量（每个处理提案的人，将会获得的奖励）
* 投票稀释率（控制提案share与loot份额占公会总share与loot份额的比率, 超过比率，则无效）；



提案流程:
1. 发起提案；
2. 赞助者赞助提案，则提案放到投票的提案队列；
3. 成员在投票期间投票；
4. 在投票结束后的缓存期（Grace Period）内，不满意的股东可以怒退；
5. 执行提案（处理提案）；


提案主要包含的信息
* 请求投票share份额（提案成功，将会奖励投票份额）
* 请求的loot份额（提案成功，奖励loot份额；怒退，或被怒踢时，可以获取loot加share相应比率的公会token金额）；
* 贡献公会的token（托管的公会托管池，提案成功时，会划转到公会银行）
* 公会需要支付的token（提案通过时，公会需要支付的token）

提案主要包含4个状态：
是否被赞助：是否执行：是否取消：是否提案通过



提案被链上执行后，将会将赞助者质押的token，退还给赞助者；
提案不通过，将会把贡献的token返回给提议者；

所有提议者贡献的，赞助者赞助的token将会放到公会银行；



资金流转模型

![molochv2-guild-bank-cash-model](/image/molochv2/molochv2-guild-bank-cash-model.png)


* 发起提案
1. 提案用户转账贡献tributeToken到DAO合约地址；
2. 划账贡献token到公会托管池ESCROW，同时添加公会总池TOTAL；

* 赞助提案
1. 赞助用户转账质押depositToken到DAO合约地址；
2. 划账质押depositToken到公会托管池ESCROW，同时添加公会总池； 

* 处理提案

提案通过的情况

1. 从托管池ESCROW，将贡献tributeToken，划转到公会池GUILD；
2. 从公会池GUILD，划转支付paymentToken，给公会用户；
3. 从托管池ESCROW，划转奖励的质押token，给公会处理提案账号；
4. 从托管池ESCROW，将剩余的质押token，退回到公会赞助者账号；

提案不通过的情况

1. 从托管池ESCROW，退回贡献tributeToken，到公会提案用户账户；
2. 从托管池ESCROW，划转奖励的质押token，给公会处理提案账号；
3. 从托管池ESCROW，将剩余的质押token，退回到公会赞助者账号；


* 取消提案
1. 从托管池ESCROW，将贡献tributeToken，划转到公会提案用户账户；


* 怒退
怒退的公会成员，可以取回给定share和loot份额的公会资产token(所有提案者贡献给公会的token)；

token份额计算公式为：
（sharesToBurn+lootToBurn）/（totalShares+totalLoot）* token(GUILD)

1. 从公会池GUILD，划转到用户的公会账户；


* 怒踢
怒踢和怒退的区别是，share份额被废除；

token份额计算公式为：
（成员loot）/（totalShares+totalLoot）* token(GUILD)

1. 从公会池GUILD，划转到用户的公会账户；



* 退款
1. DAO合约发起Token转账给用户账户；


# 总结

成员的管理

虽然可以通过发起提案这种方式，但成本太高；






[深入了解智能合约的最小代理“EIP-1167”](https://blog.csdn.net/chinadefi/article/details/121631038)  
[以太坊使用最小Gas克隆合约-合约工厂](https://zhuanlan.zhihu.com/p/252341880)   


 