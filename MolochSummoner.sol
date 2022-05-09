
pragma solidity 0.5.3;

import "./Molochv2.1.sol";
import "./CloneFactory.sol";

contract MolochSummoner is CloneFactory { 
    //Moloch 模板
    address public template;
    //DAO
    mapping (address => bool) public daos;
    uint daoIdx = 0;
    Moloch private moloch; // moloch contract
    
    constructor(address _template) public {
        template = _template;
    }
    
    event SummonComplete(address indexed moloch, address[] summoner, address[] tokens, uint256 summoningTime, uint256 periodDuration, uint256 votingPeriodLength, uint256 gracePeriodLength, uint256 proposalDeposit, uint256 dilutionBound, uint256 processingReward, uint256[] summonerShares);
    event Register(uint daoIdx, address moloch, string title, string http, uint version);
    /**
    * 基于eip-1167创建一个Moloch
    */
    function summonMoloch(
        address[] memory _summoner,//初始化成员
        address[] memory _approvedTokens,//允许的token
        uint256 _periodDuration,//每个提案发起的间隔
        uint256 _votingPeriodLength,//投票持续时间
        uint256 _gracePeriodLength,// 缓冲期（Grace Period），在此期间，对投票结果不满意的股东可以怒退
        uint256 _proposalDeposit, //提案押金， 赞助者赞成需要质押的金额
        uint256 _dilutionBound, //提案share与loot份额占公会总share与loot份额的比率, 超过比率，则无效
        uint256 _processingReward, //处理提案奖励
        uint256[] memory _summonerShares // 初始成员份额
    ) public returns (address) {
        //创建Moloch
        Moloch baal = Moloch(createClone(template));
        // 初始化Moloch
        baal.init(
            _summoner,
            _approvedTokens,
            _periodDuration,
            _votingPeriodLength,
            _gracePeriodLength,
            _proposalDeposit,
            _dilutionBound,
            _processingReward,
            _summonerShares
        );
       
        emit SummonComplete(address(baal), _summoner, _approvedTokens, now, _periodDuration, _votingPeriodLength, _gracePeriodLength, _proposalDeposit, _dilutionBound, _processingReward, _summonerShares);
        
        return address(baal);
    }
    /*
     * 注册dao
     */
    function registerDao(
        address _daoAdress,
        string memory _daoTitle,
        string memory _http,
        uint _version
      ) public returns (bool) {
          
      moloch = Moloch(_daoAdress);
      (,,,bool exists,,) = moloch.members(msg.sender);
      //必须为DAO成员， DAO没有注册
      require(exists == true, "must be a member");
      require(daos[_daoAdress] == false, "dao metadata already registered");

      daos[_daoAdress] = true;
      
      daoIdx = daoIdx + 1;
      emit Register(daoIdx, _daoAdress, _daoTitle, _http, _version);
      return true;
      
    }  
}