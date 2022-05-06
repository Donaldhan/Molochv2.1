
pragma solidity 0.5.3;

import "./oz/IERC20.sol";
import "./oz/SafeMath.sol";
import "./oz/ReentrancyGuard.sol";
/*
怒退机制（Rage Quitting）

我们认为更好的翻译是“不爽就退”，该机制来源于 Moloch ，现在被广泛运用于包括 DAOhaus 在内的多个采用 Moloch 框架的 DAO 平台或 DAO 组织。

理论上讲，靠多数投票来决定资金处置的组织是存在风险的，例如掌握70%投票权的所有者，投票通过一个提案，侵吞另外30%投票权所有者的资金。
尽管这样极端的情况还未出现，但是在股份制公司，大股东利用决策权和信息优势，收割小股东利益的事情屡见不鲜。对于投资型DAO（Venture DAO）而言，
防止具有决策权的小群体损害其他所有者的利益是十分有必要的，怒退机制便可以有效的实现这一点。

对于 Moloch 框架的 DAO 而言，任意成员可以在任何时候退出 DAO 组织，销毁自己的 Share 或者 Loot（Share 是有投票权的股份，Loot 是没有投票权的股份），
取回 DAO 当中对应份额的资金。而怒退特指在治理投票环节当中的退出行为。

以 DAOhaus 为例，治理流程被分为以下步骤：

* 提交提案：任何人（不限于DAO组织成员）都可以提交提案；
* 赞助提案：提案必须获得足够的赞助才能进入投票阶段。赞助的含义是持有 Share 的人对此提案投票表达支持，此阶段可以过滤无意义或是不重要的提案；
* 排队：提案获得的赞助超过阈值之后，进入队列，等待投票。通过排队机制，确保提案有序的汇集到投票池中；
* 投票：在投票截止日期之前，提案必须获得足够多的赞成票才可以通过；
* 缓冲期：投票通过之后，在执行投票结果之前，有一个7天的缓冲期（Grace Period），在此期间，对投票结果不满意的股东可以怒退；
* 执行：提案被标记为完成，并在链上被执行。

我们发现，在怒退机制下，任何成员都不能控制其他成员的资金，通过治理投票理论上无法伤害任意成员的利益。
事实上，怒退机制不光可以保障成员的利益，而且可以提高组织在思想上的统一性，提高组织协调效率。*/


contract Moloch is ReentrancyGuard {
    using SafeMath for uint256;

    /***************
    GLOBAL CONSTANTS
    ***************/
    // default = 17280 = 4.8 hours in seconds (5 periods per day)
    // 默认持续间隔，默认每天5个
    uint256 public periodDuration;
    // default = 35 periods (7 days) 默认投票间隔， 7天
    uint256 public votingPeriodLength;
    // default = 35 periods (7 days) 默认7天的缓冲期（Grace Period），在此期间，对投票结果不满意的股东可以怒退
    uint256 public gracePeriodLength;
    // default = 10 ETH (~$1,000 worth of ETH at contract deployment)
    // 提议需要质押的ETH？？
    uint256 public proposalDeposit;
    // default = 3 - maximum multiplier a YES voter will be obligated to pay in case of mass ragequit
    // 防止大量的怒退情况下，有义务向投票yes的投票者支付（3 - maximum multiplier）
    uint256 public dilutionBound;
    // default = 0.1 - amount of ETH to give to whoever processes a proposal
    // 奖励给任何处理提议的ETH（0.1 - amount of ETH）
    uint256 public processingReward;
    // needed to determine the current period
    // 当前时间戳
    uint256 public summoningTime;
    // internally tracks deployment under eip-1167 proxy pattern
    // 在 eip-1167代理模式下的内部部署最终标志
    bool private initialized;
    // deposit token contract reference; default = wETH
    // 质押token合约引用
    address public depositToken;

    // HARD-CODED LIMITS
    // These numbers are quite arbitrary; they are small enough to avoid overflows when doing calculations
    // with periods or shares, yet big enough to not limit reasonable use cases.
    // maximum length of voting period 最大投票间隔
    uint256 constant MAX_VOTING_PERIOD_LENGTH = 10**18;
    // maximum length of grace period 最大增长间隔
    uint256 constant MAX_GRACE_PERIOD_LENGTH = 10**18;
    // maximum dilution bound
    uint256 constant MAX_DILUTION_BOUND = 10**18;
    // maximum number of shares that can be minted 最大可以挖取的份额
    uint256 constant MAX_NUMBER_OF_SHARES_AND_LOOT = 10**18;
    // maximum number of whitelisted tokens 最大token白名单数量
    uint256 constant MAX_TOKEN_WHITELIST_COUNT = 400;
    // maximum number of tokens with non-zero balance in guildbank
    //协会央行非零tokens的数量
    uint256 constant MAX_TOKEN_GUILDBANK_COUNT = 200;

    // ***************
    // EVENTS
    // ***************
    //
    event SummonComplete(address indexed summoner, address[] tokens, uint256 summoningTime, uint256 periodDuration, uint256 votingPeriodLength, uint256 gracePeriodLength, uint256 proposalDeposit, uint256 dilutionBound, uint256 processingReward);
    //提交提议
    event SubmitProposal(address indexed applicant, uint256 sharesRequested, uint256 lootRequested, uint256 tributeOffered, address tributeToken, uint256 paymentRequested, address paymentToken, string details, bool[6] flags, uint256 proposalId, address indexed delegateKey, address indexed memberAddress);
    //
    event SponsorProposal(address indexed delegateKey, address indexed memberAddress, uint256 proposalId, uint256 proposalIndex, uint256 startingPeriod);
    //提交投票
    event SubmitVote(uint256 proposalId, uint256 indexed proposalIndex, address indexed delegateKey, address indexed memberAddress, uint8 uintVote);
    //处理提议
    event ProcessProposal(uint256 indexed proposalIndex, uint256 indexed proposalId, bool didPass);
    //处理白名单提议
    event ProcessWhitelistProposal(uint256 indexed proposalIndex, uint256 indexed proposalId, bool didPass);
    //处理协议踢出协议
    event ProcessGuildKickProposal(uint256 indexed proposalIndex, uint256 indexed proposalId, bool didPass);
    //怒退事件
    event Ragequit(address indexed memberAddress, uint256 sharesToBurn, uint256 lootToBurn);
    event TokensCollected(address indexed token, uint256 amountToCollect);
    //取消体系
    event CancelProposal(uint256 indexed proposalId, address applicantAddress);
    //更新成员代理key
    event UpdateDelegateKey(address indexed memberAddress, address newDelegateKey);
    //退款事件
    event Withdraw(address indexed memberAddress, address token, uint256 amount);

    // *******************
    // INTERNAL ACCOUNTING
    // *******************
    uint256 public proposalCount = 0; // total proposals submitted
    uint256 public totalShares = 0; // total shares across all members 成员总投票份额
    uint256 public totalLoot = 0; // total loot across all members 成员总股份份额

    uint256 public totalGuildBankTokens = 0; // total tokens with non-zero balance in guild bank

    address public constant GUILD = address(0xdead); //公会
    address public constant ESCROW = address(0xbeef); //第三方托管, 托管提议奖励的token
    address public constant TOTAL = address(0xbabe); //总token池
    //各账户的token余额
    mapping (address => mapping(address => uint256)) public userTokenBalances; // userTokenBalances[userAddress][tokenAddress]
    //投票状态
    enum Vote {
        Null, // default value, counted as abstention
        Yes,
        No
    }
    //成员
    struct Member {
        // the key responsible for submitting proposals and voting - defaults to member address unless updated
        // 提交提议或投票的key，默认为成员的地址
        address delegateKey;
        // the # of voting shares assigned to this member 成员投票份额或权重
        uint256 shares;
        // the loot amount available to this member (combined with shares on ragequit)
        // 怒退时，当前成员可用的loot份额，用于取回自己的资金
        uint256 loot;
        // always true once a member has been created
        // 成员是否创建
        bool exists;
        // highest proposal index # on which the member voted YES 最高的yes提议的索引
        uint256 highestIndexYesVote;
        // set to proposalIndex of a passing guild kick proposal for this member, prevents voting on and sponsoring proposals
        // 协会踢出成员的协议索引， 阻止投票和发起提议
        uint256 jailed;
    }
    //提案
    struct Proposal {
        // the applicant who wishes to become a member - this key will be used for withdrawals (doubles as guild kick target for gkick proposals)
        // 希望成为成员的应用， 此key可以用户退款（踢出提议的目标）
        address applicant;
        // the account that submitted the proposal (can be non-member)
        // 提交提议的账户
        address proposer;
        // the member that sponsored the proposal (moving it into the queue)
        // 赞助提议的成员
        address sponsor;
        // the # of shares the applicant is requesting
        // 应用请求的投票份额
        uint256 sharesRequested;
        // the amount of loot the applicant is requesting
        // 应用请求的loot份额
        uint256 lootRequested;
        // amount of tokens offered as tribute
        // 奖励的token数量
        uint256 tributeOffered;
        // tribute token contract reference
        // 奖励token地址
        address tributeToken;
        // amount of tokens requested as payment
        // 请求需要支付的token数量
        uint256 paymentRequested;
        // payment token contract reference
        // 支付的token地址
        address paymentToken;
        // the period in which voting can start for this proposal
        // 开始投票的时间
        uint256 startingPeriod;
        // the total number of YES votes for this proposal
        // 总共投yes的票数
        uint256 yesVotes;
        // the total number of NO votes for this proposal
        // 总共投NO的票数
        uint256 noVotes;
        // [sponsored, processed, didPass, cancelled, whitelist, guildkick]
        // 模式，阶段？？？
        bool[6] flags;
        // proposal details - could be IPFS hash, plaintext, or JSON
        //提议详情
        string details;
        // the maximum # of total shares encountered at a yes vote on this proposal
        // 投yes的最大份额和loot
        uint256 maxTotalSharesAndLootAtYesVote;
        // the votes on this proposal by each member
        // 每个成员的投票
        mapping(address => Vote) votesByMember;
    }
    // token白名单
    mapping(address => bool) public tokenWhitelist;
    address[] public approvedTokens;//授权的token

    mapping(address => bool) public proposedToWhitelist;//提议成员白名单？？
    mapping(address => bool) public proposedToKick;//踢出提议地址

    mapping(address => Member) public members;//成员
    mapping(address => address) public memberAddressByDelegateKey;//成员代理key

    mapping(uint256 => Proposal) public proposals;//提议

    uint256[] public proposalQueue; //提议队列

    //成员check
    modifier onlyMember {
        require(members[msg.sender].shares > 0 || members[msg.sender].loot > 0, "not a member");
        _;
    }
    //股票份额持有检查
    modifier onlyShareholder {
        require(members[msg.sender].shares > 0, "not a shareholder");
        _;
    }
    //成员代理检查
    modifier onlyDelegate {
        require(members[memberAddressByDelegateKey[msg.sender]].shares > 0, "not a delegate");
        _;
    }
    /**
    *
    */
    function init(
        address[] calldata _summoner, //初始成员
        address[] calldata _approvedTokens, //允许的token地址
        uint256 _periodDuration, //投票发起间隔
        uint256 _votingPeriodLength,//投票持续时间
        uint256 _gracePeriodLength,// 缓冲期（Grace Period），在此期间，对投票结果不满意的股东可以怒退
        uint256 _proposalDeposit, //提议押金
        uint256 _dilutionBound,
        uint256 _processingReward, //提议奖励
        uint256[] calldata _summonerShares // 初始成员份额
    ) external {
        require(!initialized, "initialized"); //需要未初始化
        require(_summoner.length == _summonerShares.length, "summoner length mismatches summonerShares");//初始成员及份额数量check
        //投票的持续时间，投票间隔长度检查
        require(_periodDuration > 0, "_periodDuration cannot be 0");
        require(_votingPeriodLength > 0, "_votingPeriodLength cannot be 0");
        require(_votingPeriodLength <= MAX_VOTING_PERIOD_LENGTH, "_votingPeriodLength exceeds limit");
        require(_gracePeriodLength <= MAX_GRACE_PERIOD_LENGTH, "_gracePeriodLength exceeds limit");

        require(_dilutionBound > 0, "_dilutionBound cannot be 0");
        require(_dilutionBound <= MAX_DILUTION_BOUND, "_dilutionBound exceeds limit");
        //token 数量check
        require(_approvedTokens.length > 0, "need at least one approved token");
        require(_approvedTokens.length <= MAX_TOKEN_WHITELIST_COUNT, "too many tokens");
        require(_proposalDeposit >= _processingReward, "_proposalDeposit cannot be smaller than _processingReward");//提议押金需要大于提议的奖金
        
        depositToken = _approvedTokens[0];
        //添加初始成员及相应的股份份额
        for (uint256 i = 0; i < _summoner.length; i++) {
            require(_summoner[i] != address(0), "summoner cannot be 0");
            members[_summoner[i]] = Member(_summoner[i], _summonerShares[i], 0, true, 0, 0);
            memberAddressByDelegateKey[_summoner[i]] = _summoner[i];
            totalShares = totalShares.add(_summonerShares[i]);
        }
        //check，最多的股份份额
        require(totalShares <= MAX_NUMBER_OF_SHARES_AND_LOOT, "too many shares requested");

        //初始化允许的token地址及token白名单列表
        for (uint256 i = 0; i < _approvedTokens.length; i++) {
            require(_approvedTokens[i] != address(0), "_approvedToken cannot be 0");
            require(!tokenWhitelist[_approvedTokens[i]], "duplicate approved token");
            tokenWhitelist[_approvedTokens[i]] = true;
            approvedTokens.push(_approvedTokens[i]);
        }

        periodDuration = _periodDuration;
        votingPeriodLength = _votingPeriodLength;
        gracePeriodLength = _gracePeriodLength;
        proposalDeposit = _proposalDeposit;
        dilutionBound = _dilutionBound;
        processingReward = _processingReward;
        summoningTime = now;
        initialized = true;
    }

    /*****************
    PROPOSAL FUNCTIONS 提议功能
    *****************/

    /**
     * 提交提议
     */
    function submitProposal(
        address applicant, //提议发起者
        uint256 sharesRequested,//请求股份份额
        uint256 lootRequested, //请求Loot份额
        uint256 tributeOffered, //奖励token的数量
        address tributeToken, // 奖励token地址
        uint256 paymentRequested,
        address paymentToken, // 支付token地址
        string memory details
    ) public nonReentrant returns (uint256 proposalId) {
        require(sharesRequested.add(lootRequested) <= MAX_NUMBER_OF_SHARES_AND_LOOT, "too many shares requested");
        require(tokenWhitelist[tributeToken], "tributeToken is not whitelisted"); // 需要奖励token为白名单
        require(tokenWhitelist[paymentToken], "payment is not whitelisted"); //
        require(applicant != address(0), "applicant cannot be 0");
        //发起的应用地址不能为预留地址（公会地址，token托管地址，）
        require(applicant != GUILD && applicant != ESCROW && applicant != TOTAL, "applicant address cannot be reserved");
        require(members[applicant].jailed == 0, "proposal applicant must not be jailed");

        if (tributeOffered > 0 && userTokenBalances[GUILD][tributeToken] == 0) {
            require(totalGuildBankTokens < MAX_TOKEN_GUILDBANK_COUNT, 'cannot submit more tribute proposals for new tokens - guildbank is full');
        }

        // collect tribute from proposer and store it in the Moloch until the proposal is processed
        //从建立token地址tributeToken转移奖励tributeOffered个token到当前合约
        require(IERC20(tributeToken).transferFrom(msg.sender, address(this), tributeOffered), "tribute token transfer failed");
        //更新托管的token数量及总token池数量
        unsafeAddToBalance(ESCROW, tributeToken, tributeOffered);

        bool[6] memory flags; // [sponsored, processed, didPass, cancelled, whitelist, guildkick]
        //提交提议
        _submitProposal(applicant, sharesRequested, lootRequested, tributeOffered, tributeToken, paymentRequested, paymentToken, details, flags);
        //提议索引
        return proposalCount - 1; // return proposalId - contracts calling submit might want it
    }

    function submitWhitelistProposal(address tokenToWhitelist, string memory details) public nonReentrant returns (uint256 proposalId) {
        require(tokenToWhitelist != address(0), "must provide token address");
        require(!tokenWhitelist[tokenToWhitelist], "cannot already have whitelisted the token");
        require(approvedTokens.length < MAX_TOKEN_WHITELIST_COUNT, "cannot submit more whitelist proposals");

        bool[6] memory flags; // [sponsored, processed, didPass, cancelled, whitelist, guildkick]
        flags[4] = true; // whitelist

        _submitProposal(address(0), 0, 0, 0, tokenToWhitelist, 0, address(0), details, flags);
        return proposalCount - 1;
    }

    function submitGuildKickProposal(address memberToKick, string memory details) public nonReentrant returns (uint256 proposalId) {
        Member memory member = members[memberToKick];

        require(member.shares > 0 || member.loot > 0, "member must have at least one share or one loot");
        require(members[memberToKick].jailed == 0, "member must not already be jailed");

        bool[6] memory flags; // [sponsored, processed, didPass, cancelled, whitelist, guildkick]
        flags[5] = true; // guild kick

        _submitProposal(memberToKick, 0, 0, 0, address(0), 0, address(0), details, flags);
        return proposalCount - 1;
    }
    /**
    * TODO
    */
    function _submitProposal(
        address applicant,
        uint256 sharesRequested,
        uint256 lootRequested,
        uint256 tributeOffered,
        address tributeToken,
        uint256 paymentRequested,
        address paymentToken,
        string memory details,
        bool[6] memory flags
    ) internal {
        Proposal memory proposal = Proposal({
            applicant : applicant,
            proposer : msg.sender,
            sponsor : address(0),
            sharesRequested : sharesRequested,
            lootRequested : lootRequested,
            tributeOffered : tributeOffered,
            tributeToken : tributeToken,
            paymentRequested : paymentRequested,
            paymentToken : paymentToken,
            startingPeriod : 0,
            yesVotes : 0,
            noVotes : 0,
            flags : flags,
            details : details,
            maxTotalSharesAndLootAtYesVote : 0
        });

        proposals[proposalCount] = proposal;
        address memberAddress = memberAddressByDelegateKey[msg.sender];
        // NOTE: argument order matters, avoid stack too deep
        emit SubmitProposal(applicant, sharesRequested, lootRequested, tributeOffered, tributeToken, paymentRequested, paymentToken, details, flags, proposalCount, msg.sender, memberAddress);
        proposalCount += 1;
    }
    /**
    *
    */
    function sponsorProposal(uint256 proposalId) public nonReentrant onlyDelegate {
        // collect proposal deposit from sponsor and store it in the Moloch until the proposal is processed
        require(IERC20(depositToken).transferFrom(msg.sender, address(this), proposalDeposit), "proposal deposit token transfer failed");
        unsafeAddToBalance(ESCROW, depositToken, proposalDeposit);

        Proposal storage proposal = proposals[proposalId];

        require(proposal.proposer != address(0), 'proposal must have been proposed');
        require(!proposal.flags[0], "proposal has already been sponsored");
        require(!proposal.flags[3], "proposal has been cancelled");
        require(members[proposal.applicant].jailed == 0, "proposal applicant must not be jailed");

        if (proposal.tributeOffered > 0 && userTokenBalances[GUILD][proposal.tributeToken] == 0) {
            require(totalGuildBankTokens < MAX_TOKEN_GUILDBANK_COUNT, 'cannot sponsor more tribute proposals for new tokens - guildbank is full');
        }

        // whitelist proposal
        if (proposal.flags[4]) {
            require(!tokenWhitelist[address(proposal.tributeToken)], "cannot already have whitelisted the token");
            require(!proposedToWhitelist[address(proposal.tributeToken)], 'already proposed to whitelist');
            require(approvedTokens.length < MAX_TOKEN_WHITELIST_COUNT, "cannot sponsor more whitelist proposals");
            proposedToWhitelist[address(proposal.tributeToken)] = true;

        // guild kick proposal
        } else if (proposal.flags[5]) {
            require(!proposedToKick[proposal.applicant], 'already proposed to kick');
            proposedToKick[proposal.applicant] = true;
        }

        // compute startingPeriod for proposal
        uint256 startingPeriod = max(
            getCurrentPeriod(),
            proposalQueue.length == 0 ? 0 : proposals[proposalQueue[proposalQueue.length.sub(1)]].startingPeriod
        ).add(1);

        proposal.startingPeriod = startingPeriod;

        address memberAddress = memberAddressByDelegateKey[msg.sender];
        proposal.sponsor = memberAddress;

        proposal.flags[0] = true; // sponsored

        // append proposal to the queue
        proposalQueue.push(proposalId);
        
        emit SponsorProposal(msg.sender, memberAddress, proposalId, proposalQueue.length.sub(1), startingPeriod);
    }
    /**
     * 投票
     */
    // NOTE: In MolochV2 proposalIndex !== proposalId
    function submitVote(uint256 proposalIndex, uint8 uintVote) public nonReentrant onlyDelegate {
        address memberAddress = memberAddressByDelegateKey[msg.sender];
        Member storage member = members[memberAddress];

        require(proposalIndex < proposalQueue.length, "proposal does not exist");
        Proposal storage proposal = proposals[proposalQueue[proposalIndex]];

        require(uintVote < 3, "must be less than 3");
        Vote vote = Vote(uintVote);

        require(getCurrentPeriod() >= proposal.startingPeriod, "voting period has not started");
        require(!hasVotingPeriodExpired(proposal.startingPeriod), "proposal voting period has expired");
        require(proposal.votesByMember[memberAddress] == Vote.Null, "member has already voted");
        require(vote == Vote.Yes || vote == Vote.No, "vote must be either Yes or No");

        proposal.votesByMember[memberAddress] = vote;

        if (vote == Vote.Yes) {
            proposal.yesVotes = proposal.yesVotes.add(member.shares);

            // set highest index (latest) yes vote - must be processed for member to ragequit
            if (proposalIndex > member.highestIndexYesVote) {
                member.highestIndexYesVote = proposalIndex;
            }

            // set maximum of total shares encountered at a yes vote - used to bound dilution for yes voters
            if (totalShares.add(totalLoot) > proposal.maxTotalSharesAndLootAtYesVote) {
                proposal.maxTotalSharesAndLootAtYesVote = totalShares.add(totalLoot);
            }

        } else if (vote == Vote.No) {
            proposal.noVotes = proposal.noVotes.add(member.shares);
        }
     
        // NOTE: subgraph indexes by proposalId not proposalIndex since proposalIndex isn't set untill it's been sponsored but proposal is created on submission
        emit SubmitVote(proposalQueue[proposalIndex], proposalIndex, msg.sender, memberAddress, uintVote);
    }
    /**
     *
     */
    function processProposal(uint256 proposalIndex) public nonReentrant {
        _validateProposalForProcessing(proposalIndex);

        uint256 proposalId = proposalQueue[proposalIndex];
        Proposal storage proposal = proposals[proposalId];

        require(!proposal.flags[4] && !proposal.flags[5], "must be a standard proposal");

        proposal.flags[1] = true; // processed

        bool didPass = _didPass(proposalIndex);

        // Make the proposal fail if the new total number of shares and loot exceeds the limit
        if (totalShares.add(totalLoot).add(proposal.sharesRequested).add(proposal.lootRequested) > MAX_NUMBER_OF_SHARES_AND_LOOT) {
            didPass = false;
        }

        // Make the proposal fail if it is requesting more tokens as payment than the available guild bank balance
        if (proposal.paymentRequested > userTokenBalances[GUILD][proposal.paymentToken]) {
            didPass = false;
        }

        // Make the proposal fail if it would result in too many tokens with non-zero balance in guild bank
        if (proposal.tributeOffered > 0 && userTokenBalances[GUILD][proposal.tributeToken] == 0 && totalGuildBankTokens >= MAX_TOKEN_GUILDBANK_COUNT) {
           didPass = false;
        }

        // PROPOSAL PASSED
        if (didPass) {
            proposal.flags[2] = true; // didPass

            // if the applicant is already a member, add to their existing shares & loot
            if (members[proposal.applicant].exists) {
                members[proposal.applicant].shares = members[proposal.applicant].shares.add(proposal.sharesRequested);
                members[proposal.applicant].loot = members[proposal.applicant].loot.add(proposal.lootRequested);

            // the applicant is a new member, create a new record for them
            } else {
                // if the applicant address is already taken by a member's delegateKey, reset it to their member address
                if (members[memberAddressByDelegateKey[proposal.applicant]].exists) {
                    address memberToOverride = memberAddressByDelegateKey[proposal.applicant];
                    memberAddressByDelegateKey[memberToOverride] = memberToOverride;
                    members[memberToOverride].delegateKey = memberToOverride;
                }

                // use applicant address as delegateKey by default
                members[proposal.applicant] = Member(proposal.applicant, proposal.sharesRequested, proposal.lootRequested, true, 0, 0);
                memberAddressByDelegateKey[proposal.applicant] = proposal.applicant;
            }

            // mint new shares & loot
            totalShares = totalShares.add(proposal.sharesRequested);
            totalLoot = totalLoot.add(proposal.lootRequested);

            // if the proposal tribute is the first tokens of its kind to make it into the guild bank, increment total guild bank tokens
            if (userTokenBalances[GUILD][proposal.tributeToken] == 0 && proposal.tributeOffered > 0) {
                totalGuildBankTokens += 1;
            }

            unsafeInternalTransfer(ESCROW, GUILD, proposal.tributeToken, proposal.tributeOffered);
            unsafeInternalTransfer(GUILD, proposal.applicant, proposal.paymentToken, proposal.paymentRequested);

            // if the proposal spends 100% of guild bank balance for a token, decrement total guild bank tokens
            if (userTokenBalances[GUILD][proposal.paymentToken] == 0 && proposal.paymentRequested > 0) {
                totalGuildBankTokens -= 1;
            }

        // PROPOSAL FAILED
        } else {
            // return all tokens to the proposer (not the applicant, because funds come from proposer)
            unsafeInternalTransfer(ESCROW, proposal.proposer, proposal.tributeToken, proposal.tributeOffered);
        }

        _returnDeposit(proposal.sponsor);

        emit ProcessProposal(proposalIndex, proposalId, didPass);
    }
    /**
    */
    function processWhitelistProposal(uint256 proposalIndex) public nonReentrant {
        _validateProposalForProcessing(proposalIndex);

        uint256 proposalId = proposalQueue[proposalIndex];
        Proposal storage proposal = proposals[proposalId];

        require(proposal.flags[4], "must be a whitelist proposal");

        proposal.flags[1] = true; // processed

        bool didPass = _didPass(proposalIndex);

        if (approvedTokens.length >= MAX_TOKEN_WHITELIST_COUNT) {
            didPass = false;
        }

        if (didPass) {
            proposal.flags[2] = true; // didPass

            tokenWhitelist[address(proposal.tributeToken)] = true;
            approvedTokens.push(proposal.tributeToken);
        }

        proposedToWhitelist[address(proposal.tributeToken)] = false;

        _returnDeposit(proposal.sponsor);

        emit ProcessWhitelistProposal(proposalIndex, proposalId, didPass);
    }
    /**
    *
    */
    function processGuildKickProposal(uint256 proposalIndex) public nonReentrant {
        _validateProposalForProcessing(proposalIndex);

        uint256 proposalId = proposalQueue[proposalIndex];
        Proposal storage proposal = proposals[proposalId];

        require(proposal.flags[5], "must be a guild kick proposal");

        proposal.flags[1] = true; // processed

        bool didPass = _didPass(proposalIndex);

        if (didPass) {
            proposal.flags[2] = true; // didPass
            Member storage member = members[proposal.applicant];
            member.jailed = proposalIndex;

            // transfer shares to loot
            member.loot = member.loot.add(member.shares);
            totalShares = totalShares.sub(member.shares);
            totalLoot = totalLoot.add(member.shares);
            member.shares = 0; // revoke all shares
        }

        proposedToKick[proposal.applicant] = false;

        _returnDeposit(proposal.sponsor);

        emit ProcessGuildKickProposal(proposalIndex, proposalId, didPass);
    }
    /**
    */
    function _didPass(uint256 proposalIndex) internal returns (bool didPass) {
        Proposal memory proposal = proposals[proposalQueue[proposalIndex]];

        didPass = proposal.yesVotes > proposal.noVotes;

        // Make the proposal fail if the dilutionBound is exceeded
        if ((totalShares.add(totalLoot)).mul(dilutionBound) < proposal.maxTotalSharesAndLootAtYesVote) {
            didPass = false;
        }

        // Make the proposal fail if the applicant is jailed
        // - for standard proposals, we don't want the applicant to get any shares/loot/payment
        // - for guild kick proposals, we should never be able to propose to kick a jailed member (or have two kick proposals active), so it doesn't matter
        if (members[proposal.applicant].jailed != 0) {
            didPass = false;
        }

        return didPass;
    }
    /**
    *
    */
    function _validateProposalForProcessing(uint256 proposalIndex) internal view {
        require(proposalIndex < proposalQueue.length, "proposal does not exist");
        Proposal memory proposal = proposals[proposalQueue[proposalIndex]];

        require(getCurrentPeriod() >= proposal.startingPeriod.add(votingPeriodLength).add(gracePeriodLength), "proposal is not ready to be processed");
        require(proposal.flags[1] == false, "proposal has already been processed");
        require(proposalIndex == 0 || proposals[proposalQueue[proposalIndex.sub(1)]].flags[1], "previous proposal must be processed");
    }
    /**
    *
    */
    function _returnDeposit(address sponsor) internal {
        unsafeInternalTransfer(ESCROW, msg.sender, depositToken, processingReward);
        unsafeInternalTransfer(ESCROW, sponsor, depositToken, proposalDeposit.sub(processingReward));
    }
    /**
    * @param sharesToBurn 销毁的投票份额
    * @param lootToBurn 销毁的Loot份额
    */
    function ragequit(uint256 sharesToBurn, uint256 lootToBurn) public nonReentrant onlyMember {
        _ragequit(msg.sender, sharesToBurn, lootToBurn);
    }
    /**
    */
    function _ragequit(address memberAddress, uint256 sharesToBurn, uint256 lootToBurn) internal {
        uint256 initialTotalSharesAndLoot = totalShares.add(totalLoot);
        //获取成员信息
        Member storage member = members[memberAddress];
        //检查成员投票份额和Loot份额
        require(member.shares >= sharesToBurn, "insufficient shares");
        require(member.loot >= lootToBurn, "insufficient loot");
        //必须成员最高投yes的索引提议，已经执行
        require(canRagequit(member.highestIndexYesVote), "cannot ragequit until highest index proposal member voted YES on is processed");

        uint256 sharesAndLootToBurn = sharesToBurn.add(lootToBurn);

        // burn shares and loot
        // 销毁成员的投票份额和loot份额
        member.shares = member.shares.sub(sharesToBurn);
        member.loot = member.loot.sub(lootToBurn);
        // 更新总投票份额
        totalShares = totalShares.sub(sharesToBurn);
        // 更新总Loot份额
        totalLoot = totalLoot.sub(lootToBurn);
        //todo ???
        for (uint256 i = 0; i < approvedTokens.length; i++) {
            uint256 amountToRagequit = fairShare(userTokenBalances[GUILD][approvedTokens[i]], sharesAndLootToBurn, initialTotalSharesAndLoot);
            if (amountToRagequit > 0) { // gas optimization to allow a higher maximum token limit
                // deliberately not using safemath here to keep overflows from preventing the function execution (which would break ragekicks)
                // if a token overflows, it is because the supply was artificially inflated to oblivion, so we probably don't care about it anyways
                userTokenBalances[GUILD][approvedTokens[i]] -= amountToRagequit;
                userTokenBalances[memberAddress][approvedTokens[i]] += amountToRagequit;
            }
        }

        emit Ragequit(memberAddress, sharesToBurn, lootToBurn);
    }

    function ragekick(address memberToKick) public nonReentrant {
        Member storage member = members[memberToKick];

        require(member.jailed != 0, "member must be in jail");
        require(member.loot > 0, "member must have some loot"); // note - should be impossible for jailed member to have shares
        require(canRagequit(member.highestIndexYesVote), "cannot ragequit until highest index proposal member voted YES on is processed");

        _ragequit(memberToKick, 0, member.loot);
    }

    function withdrawBalance(address token, uint256 amount) public nonReentrant {
        _withdrawBalance(token, amount);
    }

    function withdrawBalances(address[] memory tokens, uint256[] memory amounts, bool max) public nonReentrant {
        require(tokens.length == amounts.length, "tokens and amounts arrays must be matching lengths");

        for (uint256 i=0; i < tokens.length; i++) {
            uint256 withdrawAmount = amounts[i];
            if (max) { // withdraw the maximum balance
                withdrawAmount = userTokenBalances[msg.sender][tokens[i]];
            }

            _withdrawBalance(tokens[i], withdrawAmount);
        }
    }
    
    function _withdrawBalance(address token, uint256 amount) internal {
        require(userTokenBalances[msg.sender][token] >= amount, "insufficient balance");
        unsafeSubtractFromBalance(msg.sender, token, amount);
        require(IERC20(token).transfer(msg.sender, amount), "transfer failed");
        emit Withdraw(msg.sender, token, amount);
    }

    function collectTokens(address token) public onlyDelegate nonReentrant {
        uint256 amountToCollect = IERC20(token).balanceOf(address(this)).sub(userTokenBalances[TOTAL][token]);
        // only collect if 1) there are tokens to collect 2) token is whitelisted 3) token has non-zero balance
        require(amountToCollect > 0, 'no tokens to collect');
        require(tokenWhitelist[token], 'token to collect must be whitelisted');
        require(userTokenBalances[GUILD][token] > 0 || totalGuildBankTokens < MAX_TOKEN_GUILDBANK_COUNT, 'token to collect must have non-zero guild bank balance');
        
        if (userTokenBalances[GUILD][token] == 0){
            totalGuildBankTokens += 1;
        }
        
        unsafeAddToBalance(GUILD, token, amountToCollect);
        emit TokensCollected(token, amountToCollect);
    }

    // NOTE: requires that delegate key which sent the original proposal cancels, msg.sender == proposal.proposer
    function cancelProposal(uint256 proposalId) public nonReentrant {
        Proposal storage proposal = proposals[proposalId];
        require(!proposal.flags[0], "proposal has already been sponsored");
        require(!proposal.flags[3], "proposal has already been cancelled");
        require(msg.sender == proposal.proposer, "solely the proposer can cancel");

        proposal.flags[3] = true; // cancelled
        
        unsafeInternalTransfer(ESCROW, proposal.proposer, proposal.tributeToken, proposal.tributeOffered);
        emit CancelProposal(proposalId, msg.sender);
    }

    function updateDelegateKey(address newDelegateKey) public nonReentrant onlyShareholder {
        require(newDelegateKey != address(0), "newDelegateKey cannot be 0");

        // skip checks if member is setting the delegate key to their member address
        if (newDelegateKey != msg.sender) {
            require(!members[newDelegateKey].exists, "cannot overwrite existing members");
            require(!members[memberAddressByDelegateKey[newDelegateKey]].exists, "cannot overwrite existing delegate keys");
        }

        Member storage member = members[msg.sender];
        memberAddressByDelegateKey[member.delegateKey] = address(0);
        memberAddressByDelegateKey[newDelegateKey] = msg.sender;
        member.delegateKey = newDelegateKey;

        emit UpdateDelegateKey(msg.sender, newDelegateKey);
    }

    // can only ragequit if the latest proposal you voted YES on has been processed
    function canRagequit(uint256 highestIndexYesVote) public view returns (bool) {
        require(highestIndexYesVote < proposalQueue.length, "proposal does not exist");
        return proposals[proposalQueue[highestIndexYesVote]].flags[1];
    }

    function hasVotingPeriodExpired(uint256 startingPeriod) public view returns (bool) {
        return getCurrentPeriod() >= startingPeriod.add(votingPeriodLength);
    }

    /***************
    GETTER FUNCTIONS
    ***************/
    function max(uint256 x, uint256 y) internal pure returns (uint256) {
        return x >= y ? x : y;
    }

    function getCurrentPeriod() public view returns (uint256) {
        return now.sub(summoningTime).div(periodDuration);
    }

    function getProposalQueueLength() public view returns (uint256) {
        return proposalQueue.length;
    }

    function getProposalFlags(uint256 proposalId) public view returns (bool[6] memory) {
        return proposals[proposalId].flags;
    }

    function getUserTokenBalance(address user, address token) public view returns (uint256) {
        return userTokenBalances[user][token];
    }

    function getMemberProposalVote(address memberAddress, uint256 proposalIndex) public view returns (Vote) {
        require(members[memberAddress].exists, "member does not exist");
        require(proposalIndex < proposalQueue.length, "proposal does not exist");
        return proposals[proposalQueue[proposalIndex]].votesByMember[memberAddress];
    }

    function getTokenCount() public view returns (uint256) {
        return approvedTokens.length;
    }

    /***************
    HELPER FUNCTIONS 工具工鞥
    ***************/
    function unsafeAddToBalance(address user, address token, uint256 amount) internal {
        //更新当前用户持有的token数量
        userTokenBalances[user][token] += amount;
        //更新总token池数量
        userTokenBalances[TOTAL][token] += amount;
    }

    function unsafeSubtractFromBalance(address user, address token, uint256 amount) internal {
        userTokenBalances[user][token] -= amount;
        userTokenBalances[TOTAL][token] -= amount;
    }

    function unsafeInternalTransfer(address from, address to, address token, uint256 amount) internal {
        unsafeSubtractFromBalance(from, token, amount);
        unsafeAddToBalance(to, token, amount);
    }

    function fairShare(uint256 balance, uint256 shares, uint256 totalShares) internal pure returns (uint256) {
        require(totalShares != 0);

        if (balance == 0) { return 0; }

        uint256 prod = balance * shares;

        if (prod / balance == shares) { // no overflow in multiplication above?
            return prod / totalShares;
        }

        return (balance / totalShares) * shares;
    }
}
