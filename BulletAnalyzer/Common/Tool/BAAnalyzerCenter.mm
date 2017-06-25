//
//  BAAnalyzerCenter.m
//  BulletAnalyzer
//
//  Created by 张骏 on 17/6/8.
//  Copyright © 2017年 Zj. All rights reserved.
//

#import "BAAnalyzerCenter.h"
#import "BAReportModel.h"
#import "BABulletModel.h"
#import "BAGiftModel.h"
#import "BAGiftValueModel.h"
#import "BAWordsModel.h"
#import "BASentenceModel.h"
#import "BAUserModel.h"
#import "BACountTimeModel.h"
#import "BARoomModel.h"
#import "Segmentor.h"
#import "FMDatabase.h"
#import "FMDatabaseQueue.h"

static NSString *const BACompletedReport = @"completedReport"; //完成表
static NSString *const BAAnalyzingReport = @"AnalyzingReport"; //进行表
static NSString *const BAReportID = @"reportID";  //ID
static NSString *const BAReportData = @"reportData"; //数据
static NSString *const BANotice = @"notice"; //关注表
static NSString *const BANoticeID = @"noticeID"; //关注表ID
static NSString *const BANoticeData = @"noticeData"; //关注表数据

@interface BAAnalyzerCenter()
@property (nonatomic, strong) FMDatabaseQueue *dataBaseQueue;
@property (nonatomic, assign) dispatch_queue_t analyzingQueue; //用于计算的子线程

@property (nonatomic, strong) BAReportModel *analyzingReportModel; //正在分析的报告

@property (nonatomic, strong) NSMutableArray *bulletsArray; //弹幕数组 只保留前100个
@property (nonatomic, strong) NSMutableArray *wordsArray;   //单词数组 保留500个 频次低的不保留
@property (nonatomic, strong) NSMutableArray *userBulletCountArray;   //根据发言次数排序的用户数组 保留100个
@property (nonatomic, strong) NSMutableArray *levelCountArray;   //用户等级与数量关系的数组
@property (nonatomic, strong) NSMutableArray *countTimeArray;   //弹幕数量与时间关系的数组
@property (nonatomic, strong) BACountTimeModel *timeCountModel; //当前处理的时间有关模型
@property (nonatomic, strong) NSMutableArray *countTimePointArray; //弹幕数量与时间坐标数组
@property (nonatomic, strong) NSMutableArray *onlineTimePointArray; //在线数量与时间坐标数组
@property (nonatomic, strong) NSMutableArray *fansTimePointArray; //关注数量与时间坐标数组
@property (nonatomic, strong) NSMutableArray *levelCountPointArray; //等级与数量的坐标数组

@property (nonatomic, strong) NSMutableArray *giftsArray; //全部礼物
@property (nonatomic, strong) NSMutableArray *userFishBallCountArray; //根据赠送鱼丸数的用户数组
@property (nonatomic, strong) NSMutableArray *giftValueArray; //礼物价值分布数组

@property (nonatomic, strong) NSMutableArray *sentenceArray; //根据词频 余弦夹角算出来的近似度句子
@property (nonatomic, assign) CGFloat similarity; //相似度低于此值的句子会被合并 默认0.7

@property (nonatomic, assign) NSInteger timeRepeatCount; //时钟重复次数
@property (nonatomic, assign) NSInteger bulletsCount;   //弹幕次数/在采样时间内
@property (nonatomic, assign) CGFloat repeatTime; //单词重复时间


@end

@implementation BAAnalyzerCenter

#pragma mark - public
- (void)beginAnalyzing{
    _analyzing = YES;
    
    //传入报告则接着分析
    if (!_proceedReportModel) {
        //初始化各个数组
        _bulletsArray = [NSMutableArray array];
        _wordsArray = [NSMutableArray array];
        _userBulletCountArray = [NSMutableArray array];
        _countTimeArray = [NSMutableArray array];
        _countTimePointArray = [NSMutableArray array];
        _onlineTimePointArray = [NSMutableArray array];
        _fansTimePointArray = [NSMutableArray array];
        _levelCountPointArray = [NSMutableArray array];
        _levelCountArray = @[
                             @0, //0-10级
                             @0, //11-20级
                             @0, //21-30级
                             @0, //31-40级
                             @0, //41-50级
                             @0, //51-60级
                             @0, //61-70级
                             @0  //70级以上
                             ].mutableCopy;
        
        //初始化礼物数组
        _giftsArray = [NSMutableArray array];
        _userFishBallCountArray = [NSMutableArray array];
        _giftValueArray = [NSMutableArray array];
        
        //初始化近似度计算的句子
        _sentenceArray = [NSMutableArray array];
        
        for (NSInteger i = 1; i < 8; i++) {
            BAGiftValueModel *giftValueModel = [BAGiftValueModel new];
            giftValueModel.giftType = (BAGiftType)i;
            [_giftValueArray addObject:giftValueModel];
        }
        
        //初始化分析报告
        _analyzingReportModel = [BAReportModel new];
        _analyzingReportModel.bulletsArray = _bulletsArray;
        _analyzingReportModel.wordsArray = _wordsArray;
        _analyzingReportModel.userBulletCountArray = _userBulletCountArray;
        _analyzingReportModel.levelCountArray = _levelCountArray;
        _analyzingReportModel.countTimePointArray = _countTimePointArray;
        _analyzingReportModel.onlineTimePointArray = _onlineTimePointArray;
        _analyzingReportModel.fansTimePointArray = _fansTimePointArray;
        _analyzingReportModel.levelCountPointArray = _levelCountPointArray;
        _analyzingReportModel.maxActiveCount = 1;
        _analyzingReportModel.timeID = (NSInteger)[[NSDate date] timeIntervalSince1970];
        
        _analyzingReportModel.giftsArray = _giftsArray;
        _analyzingReportModel.userFishBallCountArray = _userFishBallCountArray;
        _analyzingReportModel.giftValueArray = _giftValueArray;
        
        _analyzingReportModel.sentenceArray = _sentenceArray;
        
        //传入开始分析时间
        _analyzingReportModel.begin = [NSDate date];
    } else {
        //从继续分析表中删除
        [self delReport:_analyzingReportModel];
        
        //获取继续分析模型
        _analyzingReportModel = _proceedReportModel;
        _analyzingReportModel.interruptAnalyzing = NO;
        _analyzingReportModel.proceed = [NSDate date];
        _proceedReportModel = nil;
       
        //接着分析
        _bulletsArray = _analyzingReportModel.bulletsArray;
        _wordsArray = _analyzingReportModel.wordsArray;
        _userBulletCountArray = _analyzingReportModel.userBulletCountArray;
        _levelCountArray = _analyzingReportModel.levelCountArray;
        _countTimeArray = _analyzingReportModel.countTimeArray;
        _countTimePointArray = _analyzingReportModel.countTimePointArray;
        _onlineTimePointArray = _analyzingReportModel.onlineTimePointArray;
        _fansTimePointArray = _analyzingReportModel.fansTimePointArray;
        _levelCountPointArray = _analyzingReportModel.levelCountPointArray;
        
        _giftsArray = _analyzingReportModel.giftsArray;
        _userFishBallCountArray = _analyzingReportModel.userFishBallCountArray;
        _giftValueArray = _analyzingReportModel.giftValueArray;
    
        _sentenceArray = _analyzingReportModel.sentenceArray;
    }
    
    [self beginObserving];

    //发出通知 开始分析
    [BANotificationCenter postNotificationName:BANotificationBeginAnalyzing object:nil userInfo:@{BAUserInfoKeyReportModel : _analyzingReportModel}];
}


- (void)interruptAnalyzing{
    _analyzing = NO;
    [self endObserving];
    
    //异常打断
    if (_analyzingReportModel) {
        _analyzingReportModel.interruptAnalyzing = YES;
        _analyzingReportModel.interrupt = [NSDate date];
        [_reportModelArray addObject:_analyzingReportModel];
        
        //存入本地
        [self saveReportLocolized];
    }
    
    [BANotificationCenter postNotificationName:BANotificationInterrupAnalyzing object:nil userInfo:@{BAUserInfoKeyReportModel : _analyzingReportModel}];
}


- (void)endAnalyzing{
    _analyzing = NO;
    [self endObserving];

    //停止分析
    if (_analyzingReportModel) {
        _analyzingReportModel.interruptAnalyzing = NO;
        _analyzingReportModel.end = [NSDate date];
        [_reportModelArray addObject:_analyzingReportModel];
        
        //存入本地
        [self saveReportLocolized];
    }
    
    if (_analyzingReportModel) {
        [BANotificationCenter postNotificationName:BANotificationEndAnalyzing object:nil userInfo:@{BAUserInfoKeyReportModel : _analyzingReportModel}];
    }
}


#pragma mark - private
- (void)beginObserving{
    [BANotificationCenter addObserver:self selector:@selector(bullet:) name:BANotificationBullet object:nil];
    [BANotificationCenter addObserver:self selector:@selector(gift:) name:BANotificationGift object:nil];
    
    [_cleanTimer invalidate];
    _cleanTimer = nil;
    if (!_repeatTime) {
        _repeatTime = 1.f; //默认5秒释放一次弹幕
    }

    _cleanTimer = [NSTimer scheduledTimerWithTimeInterval:_repeatTime repeats:YES block:^(NSTimer * _Nonnull timer) {
        [self cleanMemory];
        _timeRepeatCount += 1;
    }];
    
    [[NSRunLoop currentRunLoop] addTimer:_cleanTimer forMode:NSRunLoopCommonModes];
}


- (void)endObserving{
    [BANotificationCenter removeObserver:self];
    
    [_cleanTimer invalidate];
    _cleanTimer = nil;
}


- (void)getRoomInfo{
    BAHttpParams *params = [BAHttpParams new];
    params.roomId = _analyzingReportModel.roomId;
    
    //获取房间信息
    [BAHttpTool getRoomInfoWithParams:params success:^(BARoomModel *roomModel) {
        
        _analyzingReportModel.fansCount = roomModel.fans_num;
        _analyzingReportModel.weight = roomModel.owner_weight;
        _analyzingReportModel.roomName = roomModel.room_name;
        _analyzingReportModel.name = roomModel.owner_name;
        _analyzingReportModel.avatar = roomModel.avatar;
        _analyzingReportModel.photo = roomModel.room_src;
        if (_timeCountModel) {
            //存入当前时刻粉丝数量, 主播体重, 在线人数
            _timeCountModel.fansCount = roomModel.fans_num;
            _timeCountModel.weight = roomModel.owner_weight;
            _timeCountModel.online = roomModel.online;
            //存入最大在线人数, 最小在线人数, 最大粉丝数量, 最小粉丝数量, 粉丝增长量
            _analyzingReportModel.maxOnlineCount = _analyzingReportModel.maxOnlineCount > roomModel.online.integerValue ? _analyzingReportModel.maxOnlineCount : roomModel.online.integerValue;
            _analyzingReportModel.minOnlineCount = _analyzingReportModel.minOnlineCount < roomModel.online.integerValue && _analyzingReportModel.minOnlineCount  ? _analyzingReportModel.minOnlineCount : roomModel.online.integerValue;
            _analyzingReportModel.maxFansCount = _analyzingReportModel.maxFansCount > roomModel.fans_num.integerValue ? _analyzingReportModel.maxFansCount : roomModel.fans_num.integerValue;
            _analyzingReportModel.minFansCount = _analyzingReportModel.minFansCount < roomModel.fans_num.integerValue && _analyzingReportModel.minFansCount ? _analyzingReportModel.minFansCount : roomModel.fans_num.integerValue;
            _analyzingReportModel.fansIncrese = _analyzingReportModel.maxFansCount - _analyzingReportModel.minFansCount;
            _timeCountModel = nil;
            
            //根据上面的数据计算在线人数, 粉丝数量绘图坐标数组
            [_onlineTimePointArray removeAllObjects];
            [_fansTimePointArray removeAllObjects];
            [_countTimeArray enumerateObjectsUsingBlock:^(BACountTimeModel *obj, NSUInteger idx, BOOL * _Nonnull stop) {
                
                CGPoint point1 = CGPointMake(BAFansReportDrawViewWidth * (CGFloat)idx / (_countTimeArray.count - 1), BAFansReportDrawViewHeight * (1 - ((CGFloat)(obj.online.integerValue - _analyzingReportModel.minOnlineCount) / (_analyzingReportModel.maxOnlineCount - _analyzingReportModel.minOnlineCount))));
                [_onlineTimePointArray addObject:[NSValue valueWithCGPoint:point1]];
                
                CGPoint point2 = CGPointMake(BAFansReportDrawViewWidth * (CGFloat)idx / (_countTimeArray.count - 1), BAFansReportDrawViewHeight * (1 - ((CGFloat)(obj.fansCount.integerValue - _analyzingReportModel.minFansCount) / (_analyzingReportModel.maxFansCount - _analyzingReportModel.minFansCount))));
                [_fansTimePointArray addObject:[NSValue valueWithCGPoint:point2]];
            }];
        }
    } fail:^(NSString *error) {
        NSLog(@"获取直播间详情失败");
    }];
}


- (void)gift:(NSNotification *)sender{
    //取出礼物
    NSArray *giftModelArray = sender.userInfo[BAUserInfoKeyGift];
    
    [self giftCaculate:giftModelArray];
    
    [_giftsArray addObjectsFromArray:giftModelArray];
}


- (void)giftCaculate:(NSArray *)giftModelArray{
    
    dispatch_sync(self.analyzingQueue, ^{
        [giftModelArray enumerateObjectsUsingBlock:^(BAGiftModel *obj, NSUInteger idx, BOOL * _Nonnull stop) {
            
            switch (obj.giftType) {
                case BAGiftTypeFishBall:
                    
                    [self dealWithFishBall:obj];
                    
                    break;
                    
                case BAGiftTypeFreeGift:
                {
                    BAGiftValueModel *giftValue = _giftValueArray[0];
                    [self dealWithGift:obj giftValue:giftValue];
                    break;
                }
                case BAGiftTypeCostGift:
                {
                    BAGiftValueModel *giftValue = _giftValueArray[1];
                    [self dealWithGift:obj giftValue:giftValue];
                    
                    break;
                }
                case BAGiftTypeDeserveLevel1:
                {
                    BAGiftValueModel *giftValue = _giftValueArray[2];
                    [self dealWithGift:obj giftValue:giftValue];
                    
                    break;
                }
                case BAGiftTypeDeserveLevel2:
                {
                    BAGiftValueModel *giftValue = _giftValueArray[3];
                    [self dealWithGift:obj giftValue:giftValue];
                    
                    break;
                }
                case BAGiftTypeDeserveLevel3:
                {
                    BAGiftValueModel *giftValue = _giftValueArray[4];
                    [self dealWithGift:obj giftValue:giftValue];
                    
                    break;
                }
                case BAGiftTypePlane:
                {
                    BAGiftValueModel *giftValue = _giftValueArray[5];
                    [self dealWithGift:obj giftValue:giftValue];
                    
                    break;
                }
                case BAGiftTypeRocket:
                {
                    BAGiftValueModel *giftValue = _giftValueArray[6];
                    [self dealWithGift:obj giftValue:giftValue];
                    
                    break;
                }
                default:
                    
                    break;
            }
        }];
    });
}


- (void)dealWithFishBall:(BAGiftModel *)fishBall{
    
    if (!fishBall.uid.length) return;
    
    //送鱼丸次数
    __block BOOL contained = NO;
    [_userFishBallCountArray enumerateObjectsUsingBlock:^(BAUserModel *userModel, NSUInteger idx, BOOL * _Nonnull stop3) {
        
        contained = [fishBall isEqual:userModel];
        if (contained) {
            *stop3 = YES;
            userModel.fishBallCount = BAStringWithInteger(userModel.fishBallCount.integerValue + 1);
        }
    }];
    if (!contained) {
        BAUserModel *newUserModel = [BAUserModel userModelWithGift:fishBall];
        [_userFishBallCountArray addObject:newUserModel];
    }
}


- (void)dealWithGift:(BAGiftModel *)giftModel giftValue:(BAGiftValueModel *)giftValue{
    __block BOOL contained = NO;
    [giftValue.userModelArray enumerateObjectsUsingBlock:^(BAUserModel *userModel, NSUInteger idx, BOOL * _Nonnull stop3) {
        
        contained = [giftModel isEqual:userModel];
        if (contained) {
            *stop3 = YES;
            userModel.giftCount = BAStringWithInteger(userModel.giftCount.integerValue + 1);
        }
    }];
    if (!contained) {
        BAUserModel *newUserModel = [BAUserModel userModelWithGift:giftModel];
        [giftValue.userModelArray addObject:newUserModel];
    }
}


- (void)bullet:(NSNotification *)sender{
    //取出弹幕
    NSArray *bulletModelArray = sender.userInfo[BAUserInfoKeyBullet];
    
    //分析弹幕
    [self caculate:bulletModelArray];
    
    //将弹幕加入公开的弹幕数组, 去除重复的弹幕
    [bulletModelArray enumerateObjectsUsingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        if (![_bulletsArray containsObject:obj]) {
            [_bulletsArray addObject:obj];
            //记录新增弹幕数量
            _bulletsCount += 1;
        }
    }];
}


- (void)cleanMemory{
    
    dispatch_sync(self.analyzingQueue, ^{
        
        //根据用户发言的次数排序
        NSInteger params = 5;
        if ((double)_timeRepeatCount/params - _timeRepeatCount/params == 0) { //5秒处理一次用户/用户等级
        
            //只保留最新100个弹幕
            if (_bulletsArray.count > 200) {
                [_bulletsArray removeObjectsInRange:NSMakeRange(0, _bulletsArray.count - 100)];
            }
            
            //根据词出现的频次排序
            [_wordsArray sortUsingComparator:^NSComparisonResult(BAWordsModel *wordsModel1, BAWordsModel *wordsModel2) {
                return wordsModel1.count.integerValue > wordsModel2.count.integerValue ? NSOrderedAscending : NSOrderedDescending;
            }];
            //去掉排序400之后的词
            if (_wordsArray.count > 700) {
                [_wordsArray removeObjectsInRange:NSMakeRange(400, _wordsArray.count - 400)];
            }
            
            //句子数量全部减一
            [_sentenceArray enumerateObjectsUsingBlock:^(BASentenceModel *obj, NSUInteger idx, BOOL * _Nonnull stop) {
                [obj decrease];
            }];
        }
        
        //根据用户发言的次数排序
        params = 20;
        if ((double)_timeRepeatCount/params - _timeRepeatCount/params == 0) { //20秒处理一次用户/用户等级
            
            [_userBulletCountArray sortUsingComparator:^NSComparisonResult(BAUserModel *userModel1, BAUserModel *userModel2) {
                return userModel1.count.integerValue > userModel2.count.integerValue ? NSOrderedAscending : NSOrderedDescending;
            }];
            BAUserModel *userModel = [_userBulletCountArray firstObject];
            _analyzingReportModel.maxActiveCount = userModel.count.integerValue;
            
            //去掉发言数排名100名之后的人
            if (_userBulletCountArray.count > 200) {
                [_userBulletCountArray removeObjectsInRange:NSMakeRange(100, _userBulletCountArray.count - 100)];
            }
            
            //赠送鱼丸排序
            [_userFishBallCountArray sortUsingComparator:^NSComparisonResult(BAUserModel *userModel1, BAUserModel *userModel2) {
               return userModel1.fishBallCount.integerValue > userModel2.fishBallCount.integerValue ? NSOrderedAscending : NSOrderedDescending;
            }];
        }
        
        params = 30;
        if ((double)_timeRepeatCount/params - _timeRepeatCount/params == 0) { //30秒处理弹幕数量 以及当前观看人数 主播体重
            
            //新建弹幕信息与时间关系的模型
            BACountTimeModel *countTimeModel = [BACountTimeModel new];
            countTimeModel.count = BAStringWithInteger(_bulletsCount);
            countTimeModel.time = [NSDate date];
            
            _timeCountModel = countTimeModel;
            [self getRoomInfo];
            
            [_countTimeArray addObject:countTimeModel];
            
            //记录最大弹幕数字
            _analyzingReportModel.maxBulletCount = _bulletsCount > _analyzingReportModel.maxBulletCount ? _bulletsCount : _analyzingReportModel.maxBulletCount;
            
            //计算弹幕数量与时间的坐标
            CGFloat width = BAScreenWidth;
            CGFloat height = width;
            
            [_countTimePointArray removeAllObjects];
            [_countTimeArray enumerateObjectsUsingBlock:^(BACountTimeModel *obj, NSUInteger idx, BOOL * _Nonnull stop) {
                
                CGPoint point = CGPointMake(width * (CGFloat)idx / (_countTimeArray.count - 1), height * (1 - ((CGFloat)obj.count.integerValue / _analyzingReportModel.maxBulletCount)));
                [_countTimePointArray addObject:[NSValue valueWithCGPoint:point]];
            }];
            
            _bulletsCount = 0;
        }
    });
}


- (void)caculate:(NSArray *)bulletsArray{
    
    dispatch_sync(self.analyzingQueue, ^{
        [bulletsArray enumerateObjectsUsingBlock:^(BABulletModel *bulletModel, NSUInteger idx, BOOL * _Nonnull stop1) {
            
            if (!_analyzingReportModel.roomId.length) {
                _analyzingReportModel.roomId = bulletModel.rid;
                [self getRoomInfo];
            }
            
            //分析单词及语义
            [self analyzingWords:bulletModel];
            
            //分析发送人
            [self analyzingUser:bulletModel];
        }];
    });
}


- (void)analyzingWords:(BABulletModel *)bulletModel{
    
    //结巴分词
    NSArray *wordsArray = [self stringCutByJieba:bulletModel.txt];
    
    //词频分析
    [wordsArray enumerateObjectsUsingBlock:^(NSString *words, NSUInteger idx, BOOL * _Nonnull stop2) {
        
        if (![self isIgnore:words]) { //筛选
            
            //记录词的出现频率
            __block BOOL contained = NO;
            [_wordsArray enumerateObjectsUsingBlock:^(BAWordsModel *wordsModel, NSUInteger idx, BOOL * _Nonnull stop3) {
                
                contained = [wordsModel isEqual:words];
                if (contained) {
                    *stop3 = YES;
                    wordsModel.count = BAStringWithInteger(wordsModel.count.integerValue + 1);
                    [wordsModel.bulletArray addObject:bulletModel];
                }
            }];
            if (!contained) {
                BAWordsModel *newWordsModel = [BAWordsModel new];
                newWordsModel.words = words;
                newWordsModel.count = BAStringWithInteger(1);
                newWordsModel.bulletArray = [NSMutableArray array];
                [newWordsModel.bulletArray addObject:bulletModel];
                
                [_wordsArray addObject:newWordsModel];
            }
        }
    }];
    
    //词义分析
    BASentenceModel *newSentence = [BASentenceModel new];
    newSentence.text = bulletModel.txt;
    newSentence.wordsArray = wordsArray;
    newSentence.count = 1;
    
    __block NSMutableDictionary *wordsDic = [NSMutableDictionary dictionary];
    [wordsArray enumerateObjectsUsingBlock:^(NSString *obj1, NSUInteger idx1, BOOL * _Nonnull stop1) {
        
        //若字典中已有这个词的词频 则停止计算
        if ([[wordsDic objectForKey:obj1] integerValue]) {
            *stop1 = YES;
        } else {
            __block NSInteger count = 1;
            [wordsArray enumerateObjectsUsingBlock:^(NSString *obj2, NSUInteger idx2, BOOL * _Nonnull stop2) {
                if ([obj1 isEqualToString:obj2] && idx1 != idx2) {
                    count += 1;
                }
            }];
            
            [wordsDic setObject:@(count) forKey:obj1];
        }
    }];
    
    newSentence.wordsDic = wordsDic.copy;
    
    __block BOOL similar = NO;
    [_sentenceArray enumerateObjectsUsingBlock:^(BASentenceModel *sentence, NSUInteger idx, BOOL * _Nonnull stop) {
    
        //计算余弦角度
        //两个向量内积
        //两个向量模长乘积
        __block NSInteger A = 0; //两个向量内积
        __block NSInteger B = 0; //第一个句子的模长乘积的平方
        __block NSInteger C = 0; //第二个句子的模长乘积的平方
        [sentence.wordsDic.copy enumerateKeysAndObjectsUsingBlock:^(NSString *key1, NSNumber *value1, BOOL * _Nonnull stop) {
    
            NSNumber *value2 = [wordsDic objectForKey:key1];
            if (value2.integerValue) {
                A += (value1.integerValue * value2.integerValue);
            } else {
                A += 0;
            }
            
            B += value1.integerValue * value1.integerValue;
        }];
        
        [wordsDic enumerateKeysAndObjectsUsingBlock:^(NSString *key2, NSNumber *value2, BOOL * _Nonnull stop) {
            
            C += value2.integerValue * value2.integerValue;
        }];
        
        CGFloat percent = A / (sqrt(B) * sqrt(C));
        
        if (percent > self.similarity) { //7成相似 则合并
            *stop = YES;
            similar = YES;
            sentence.count += 1;
        }
    }];
    
    if (!similar) {
        newSentence.container = _sentenceArray;
        [_sentenceArray addObject:newSentence];
    }
//    NSArray *countTotal = [_sentenceArray valueForKeyPath:@"@unionOfObjects.count"];
//    NSNumber *sumCount = [countTotal valueForKeyPath:@"@sum.integerValue"];
//    NSLog(@"_bulletsArray:%zd--_sentenceArray:%zd--_sentence:%@", _bulletsArray.count, _sentenceArray.count, sumCount);
}


- (BOOL)isIgnore:(NSString *)string{
    //过滤小于2的词, 过滤表情
    return string.length < 2 || [string containsString:@"emot"] || [string containsString:@"dy"];
}


- (void)analyzingUser:(BABulletModel *)bulletModel{
    
    //记录用户发言次数
    __block BOOL contained1 = NO;
    [_userBulletCountArray enumerateObjectsUsingBlock:^(BAUserModel *userModel, NSUInteger idx, BOOL * _Nonnull stop) {
        
        contained1 = [bulletModel.uid isEqualToString:userModel.uid];
        if (contained1) {
            *stop = YES;
            userModel.count = BAStringWithInteger(userModel.count.integerValue + 1);
            [userModel.bulletArray addObject:bulletModel];
        }
    }];
    
    if (!contained1) {
        BAUserModel *userModel = [BAUserModel userModelWithBullet:bulletModel];
        [userModel.bulletArray addObject:bulletModel];
        
        [_userBulletCountArray addObject:userModel];
    }
  
    //记录用户等级分布
    if (bulletModel.level.integerValue <= 10) {
        _levelCountArray[0] = @([_levelCountArray[0] integerValue] + 1);
    } else if (bulletModel.level.integerValue <= 20) {
        _levelCountArray[1] = @([_levelCountArray[1] integerValue] + 1);
    } else if (bulletModel.level.integerValue <= 30) {
        _levelCountArray[2] = @([_levelCountArray[2] integerValue] + 1);
    } else if (bulletModel.level.integerValue <= 40) {
        _levelCountArray[3] = @([_levelCountArray[3] integerValue] + 1);
    } else if (bulletModel.level.integerValue <= 50) {
        _levelCountArray[4] = @([_levelCountArray[4] integerValue] + 1);
    } else if (bulletModel.level.integerValue <= 60) {
        _levelCountArray[5] = @([_levelCountArray[5] integerValue] + 1);
    } else if (bulletModel.level.integerValue <= 70) {
        _levelCountArray[6] = @([_levelCountArray[6] integerValue] + 1);
    } else {
        _levelCountArray[7] = @([_levelCountArray[7] integerValue] + 1);
    }
    
    //计算总等级以及总用户量, 用以计算平均等级
    _analyzingReportModel.levelSum += bulletModel.level.integerValue;
    _analyzingReportModel.levelCount += 1;
    
    //计算等级分布图的坐标
    [_levelCountPointArray removeAllObjects];
    NSInteger maxLevelCount = [[_levelCountArray valueForKeyPath:@"@max.integerValue"] integerValue];
    [_levelCountArray enumerateObjectsUsingBlock:^(NSString *obj, NSUInteger idx, BOOL * _Nonnull stop) {
        
        CGPoint point = CGPointMake(BAFansReportDrawViewWidth * (CGFloat)idx / (_levelCountArray.count - 1), BAFansReportDrawViewHeight * (1 - ((CGFloat)obj.integerValue / maxLevelCount)));
        [_levelCountPointArray addObject:[NSValue valueWithCGPoint:point]];
    }];
}


- (NSArray *)stringCutByJieba:(NSString *)string{
    
    //结巴分词, 转为词数组
    const char* sentence = [string UTF8String];
    std::vector<std::string> words;
    JiebaCut(sentence, words);
    std::string result;
    result << words;
    
    NSString *relustString = [NSString stringWithUTF8String:result.c_str()].copy;
    
    relustString = [relustString stringByReplacingOccurrencesOfString:@"[" withString:@""];
    relustString = [relustString stringByReplacingOccurrencesOfString:@"]" withString:@""];
    relustString = [relustString stringByReplacingOccurrencesOfString:@" " withString:@""];
    relustString = [relustString stringByReplacingOccurrencesOfString:@"\"" withString:@""];
    NSArray *wordsArray = [relustString componentsSeparatedByString:@","];
    
    return wordsArray;
}


////编辑距离分析法
//- (CGFloat)similarPercentWithStringA:(NSString *)stringA andStringB:(NSString *)stringB{
//    NSInteger n = stringA.length;
//    NSInteger m = stringB.length;
//    if (m == 0 || n == 0) return 0;
//    
//    //Construct a matrix, need C99 support
//    NSInteger matrix[n + 1][m + 1];
//    memset(&matrix[0], 0, m + 1);
//    for(NSInteger i=1; i<=n; i++) {
//        memset(&matrix[i], 0, m + 1);
//        matrix[i][0] = i;
//    }
//    for(NSInteger i = 1; i <= m; i++) {
//        matrix[0][i] = i;
//    }
//    for(NSInteger i = 1; i <= n; i++) {
//        unichar si = [stringA characterAtIndex:i - 1];
//        for(NSInteger j = 1; j <= m; j++) {
//            unichar dj = [stringB characterAtIndex:j-1];
//            NSInteger cost;
//            if(si == dj){
//                cost = 0;
//            } else {
//                cost = 1;
//            }
//            const NSInteger above = matrix[i - 1][j] + 1;
//            const NSInteger left = matrix[i][j - 1] + 1;
//            const NSInteger diag = matrix[i - 1][j - 1] + cost;
//            matrix[i][j] = MIN(above, MIN(left, diag));
//        }
//    }
//    return 100.0 - 100.0 * matrix[n][m] / stringA.length;
//}


- (dispatch_queue_t)analyzingQueue{
    //用来计算的子线程
    if (!_analyzingQueue) {
        _analyzingQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    }
    return _analyzingQueue;
}


#pragma mark - dataLocolize
- (void)updateReportLocolized{
    
    [_dataBaseQueue inDatabase:^(FMDatabase * _Nonnull db) {
        
        NSMutableArray *tempArray = [NSMutableArray array];
        NSMutableArray *noticeTempArray = [NSMutableArray array];
        BOOL open = [db open];
        if (open) {
            //创表(若无) 1.完成分析表
            NSString *execute1 = [NSString stringWithFormat:@"CREATE TABLE IF NOT EXISTS %@ (ID integer primary key autoincrement, %@ integer, %@ Blob)", BACompletedReport, BAReportID, BAReportData];
            BOOL createCompletedReportTable = [db executeUpdate:execute1];
            if (createCompletedReportTable) {
                NSLog(@"completedReport创表成功");
            } else {
                NSLog(@"completedReport创表失败");
            }
            
            //未完成分析表
            NSString *execute2 = [NSString stringWithFormat:@"CREATE TABLE IF NOT EXISTS %@ (ID integer primary key autoincrement, %@ integer, %@ Blob)", BAAnalyzingReport, BAReportID, BAReportData];
            BOOL createAnalyzingReportTable = [db executeUpdate:execute2];
            if (createAnalyzingReportTable) {
                NSLog(@"AnalyzingReportTable创表成功");
            } else {
                NSLog(@"AnalyzingReportTable创表失败");
            }
            
            //先取出完成表来里的数据解档
            NSString *select1 = [NSString stringWithFormat:@"SELECT * FROM %@ ORDER BY ID DESC", BACompletedReport];
            FMResultSet *result1 = [db executeQuery:select1];
            while (result1.next) {
                NSData *reportData = [result1 dataForColumn:BAReportData];
                BAReportModel *reportModel = [NSKeyedUnarchiver unarchiveObjectWithData:reportData];
                
                if (reportModel) {
                    [tempArray addObject:reportModel];
                }
            }
            
            //再取出未完成表来里的数据解档
            NSString *select2 = [NSString stringWithFormat:@"SELECT * FROM %@ ORDER BY ID DESC", BAAnalyzingReport];
            FMResultSet *result2 = [db executeQuery:select2];
            while (result2.next) {
                
                NSData *reportData = [result2 dataForColumn:BAReportData];
                BAReportModel *reportModel = [NSKeyedUnarchiver unarchiveObjectWithData:reportData];
                
                if (reportModel) {
                    [tempArray addObject:reportModel];
                }
            }
            
            //关注表
            NSString *execute3 = [NSString stringWithFormat:@"CREATE TABLE IF NOT EXISTS %@ (ID integer primary key autoincrement, %@ integer, %@ Blob)", BANotice, BANoticeID, BANoticeData];
            BOOL createNoticeTable = [db executeUpdate:execute3];
            if (createNoticeTable) {
                NSLog(@"noticeTable创表成功");
            } else {
                NSLog(@"noticeTable创表失败");
            }
            
            //再取出关注表来里的数据解档
            NSString *select3 = [NSString stringWithFormat:@"SELECT * FROM %@ ORDER BY ID DESC", BANotice];
            FMResultSet *result3 = [db executeQuery:select3];
            while (result3.next) {
                
                NSData *noticeData = [result3 dataForColumn:BANoticeData];
                BABulletModel *bulletModel = [NSKeyedUnarchiver unarchiveObjectWithData:noticeData];
                
                if (bulletModel) {
                    [noticeTempArray addObject:bulletModel];
                }
            }
            
            [db close];
        }
        _reportModelArray = tempArray;
        _noticeArray = noticeTempArray;
        
        [BANotificationCenter postNotificationName:BANotificationUpdateReporsComplete object:nil userInfo:@{BAUserInfoKeyReportModelArray : _reportModelArray}];
    }];
}


- (void)saveReportLocolized{
    //存入本地
    [_dataBaseQueue inDatabase:^(FMDatabase * _Nonnull db) {
        
        BOOL open = [db open];
        if (open) {
            
            //判断是否为未完成分析表分别存入表单
            NSString *insert;
            if (_analyzingReportModel.isInterruptAnalyzing) {
                insert = [NSString stringWithFormat:@"INSERT INTO %@ (%@, %@) VALUES (?, ?)", BAAnalyzingReport, BAReportID, BAReportData];
            } else {
                insert = [NSString stringWithFormat:@"INSERT INTO %@ (%@, %@) VALUES (?, ?)", BACompletedReport, BAReportID, BAReportData];
            }
            NSData *reportData = [NSKeyedArchiver archivedDataWithRootObject:_analyzingReportModel];
            BOOL success = [db executeUpdate:insert, @(_analyzingReportModel.timeID), reportData];
            if (!success) {
                NSLog(@"储存失败");
            }
            [db close];
        }
    }];
}


- (void)delReport:(BAReportModel *)report{
    
    BOOL isInterruptAnalyzing = report.isInterruptAnalyzing;
    
    [self.dataBaseQueue inDatabase:^(FMDatabase * _Nonnull db) {
        BOOL open = [db open];
        if (open) {
            
            //判断是否为未完成分析表分别存入表单
            NSString *del;
            if (isInterruptAnalyzing) {
                del = [NSString stringWithFormat:@"DELETE FROM %@ WHERE %@ = (?);", BAAnalyzingReport, BAReportID];
            } else {
                del = [NSString stringWithFormat:@"DELETE FROM %@ WHERE %@ = (?);", BACompletedReport, BAReportID];
            }
            BOOL success = [db executeUpdate:del, @(report.timeID)];
            if (!success) {
                NSLog(@"删除失败");
            } else {
                if (!isInterruptAnalyzing) {
                    [_reportModelArray removeObject:report];
                }
            }
            [db close];
        }
    }];
}


- (void)addNotice:(BABulletModel *)bulletModel{
    //先添加入数组
    [_noticeArray addObject:bulletModel];
    NSMutableArray *tempArray = [NSMutableArray array];
    [_noticeArray enumerateObjectsUsingBlock:^(BABulletModel *obj, NSUInteger idx, BOOL * _Nonnull stop) {
        if (bulletModel.uid.integerValue == obj.uid.integerValue) {
            [tempArray addObject:obj]; //遍历 获取这个用户被标记次数
        }
    }];
    
    
    [self.dataBaseQueue inDatabase:^(FMDatabase * _Nonnull db) {
        BOOL open = [db open];
        if (open) {

            //删除这个用户所有的标记
            NSString *del = [NSString stringWithFormat:@"DELETE FROM %@ WHERE %@ = (?);", BANotice, BANoticeID];
            BOOL success = [db executeUpdate:del, @(bulletModel.uid.integerValue)];
            if (!success) {
                NSLog(@"删除失败");
            } else {
                //写入这个用户被标记次数并存入表格
                [tempArray enumerateObjectsUsingBlock:^(BABulletModel *obj, NSUInteger idx, BOOL * _Nonnull stop) {
                    obj.noticeCount = tempArray.count;
                    //存入表单
                    NSString *insert = [NSString stringWithFormat:@"INSERT INTO %@ (%@, %@) VALUES (?, ?)", BANotice, BANoticeID, BANoticeData];
                    NSData *noticeData = [NSKeyedArchiver archivedDataWithRootObject:obj];
                    BOOL success = [db executeUpdate:insert, @(obj.uid.integerValue), noticeData];
                    if (!success) {
                        NSLog(@"储存失败");
                    }
                }];
            }
            
            [db close];
        }
    }];
}


- (void)delNotice:(BABulletModel *)bulletModel{
    
    bulletModel.noticeCount = 0;

    [self.dataBaseQueue inDatabase:^(FMDatabase * _Nonnull db) {
        BOOL open = [db open];
        if (open) {
            
            //删除
            NSString *del = [NSString stringWithFormat:@"DELETE FROM %@ WHERE %@ = (?);", BANotice, BANoticeID];
            BOOL success = [db executeUpdate:del, @(bulletModel.uid.integerValue)];
            if (!success) {
                NSLog(@"删除失败");
            } else {
                [_noticeArray enumerateObjectsUsingBlock:^(BABulletModel *obj, NSUInteger idx, BOOL * _Nonnull stop) {
                    if ([obj.uid isEqualToString:bulletModel.uid]) {
                        [_noticeArray removeObject:obj];
                    }
                }];
            }
            [db close];
        }
    }];
}


#pragma mark - singleton
//单例类的静态实例对象，因对象需要唯一性，故只能是static类型
static BAAnalyzerCenter *defaultCenter = nil;

/**
 单例模式对外的唯一接口，用到的dispatch_once函数在一个应用程序内只会执行一次，且dispatch_once能确保线程安全
 */
+ (BAAnalyzerCenter *)defaultCenter{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (defaultCenter == nil) {
            defaultCenter = [[self alloc] init];
            
            //从本地取出报告
            NSString *filePath = [BAPathDocument stringByAppendingPathComponent:BAReportDatabase];
            defaultCenter.dataBaseQueue = [FMDatabaseQueue databaseQueueWithPath:filePath];
            [defaultCenter updateReportLocolized];
            defaultCenter.similarity = 0.7f;
            
            NSString *dictPath = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"iosjieba.bundle/dict/jieba.dict.small.utf8"];
            NSString *hmmPath = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"iosjieba.bundle/dict/hmm_model.utf8"];
            NSString *userDictPath = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"iosjieba.bundle/dict/user.dict.utf8"];
            
            NSLog(@"%@",dictPath);
            NSLog(@"%@",hmmPath);
            NSLog(@"%@",hmmPath);
            
            const char *cDictPath = [dictPath UTF8String];
            const char *cHmmPath = [hmmPath UTF8String];
            const char *cUserDictPath = [userDictPath UTF8String];
            
            JiebaInit(cDictPath, cHmmPath, cUserDictPath);
        }
    });
    return defaultCenter;
}

/**
 覆盖该方法主要确保当用户通过[[Singleton alloc] init]创建对象时对象的唯一性，alloc方法会调用该方法，只不过zone参数默认为nil，因该类覆盖了allocWithZone方法，所以只能通过其父类分配内存，即[super allocWithZone:zone]
 */
+ (instancetype)allocWithZone:(struct _NSZone *)zone{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (defaultCenter == nil) {
            defaultCenter = [super allocWithZone:zone];
        }
    });
    return defaultCenter;
}

//覆盖该方法主要确保当用户通过copy方法产生对象时对象的唯一性
- (id)copy{
    return self;
}

//覆盖该方法主要确保当用户通过mutableCopy方法产生对象时对象的唯一性
- (id)mutableCopy{
    return self;
}

@end