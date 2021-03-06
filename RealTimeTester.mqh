//+------------------------------------------------------------------+
//|                                               RealTimeTester.mqh |
//|                                                    Denis Zhilkin |
//|                   https://github.com/DenisZhilkin/RealTimeTester |
//+------------------------------------------------------------------+
#property copyright "Denis Zhilkin"
#property link      "https://github.com/DenisZhilkin/RealTimeTester"
#property version   "1.00"

enum ENUM_DESTINATION {B, S};

class COrder
{
public:
    uint               position; // position index
protected:
    string             symbol;
    ENUM_DESTINATION   destination;
    ulong              volume;
    double             price, sl, tp;
    bool               accepted;
    double             epsilon;
    long               last_tick_time;

public:
    COrder()
    {
        position = NULL;
        accepted = false;
    };

    virtual ulong UpdateExecution(MqlBookInfo &book[], MqlTick &tick) {return 0;};
    // get properties
    string           Symbol()        {return symbol;};
    double           Price()         {return price;};
    double           Sl()            {return sl;};
    double           Tp()            {return tp;}; 
    ulong            Volume()        {return volume;};
    bool             Accepted()      {return accepted;};
    double           Epsilon()       {return epsilon;};
    ENUM_DESTINATION Destination()   {return destination;};
    
protected:   
    bool Init(string _symbol=NULL, ENUM_DESTINATION _destination=B, ulong _volume=1, double _sl=NULL, double _tp=NULL)
    {
        if(_symbol == NULL)
            symbol  = _Symbol;
        else   
            symbol  = _symbol;
        
        destination = _destination;
        volume      = _volume;
        if(!CheckSlTp(NULL, _sl, _tp)) return false;
        sl          = _sl;
        tp          = _tp;
        epsilon     = 1.0 / pow(10, SymbolInfoInteger(symbol, SYMBOL_DIGITS) + 1);
        return true;
    };
    
    bool CheckSlTp(double _price, double _sl, double _tp)
    {
        if(_price == NULL) _price = price;
        if (destination == B)
            return (_sl == NULL || _sl < _price) || (_tp == NULL || _tp > _price);
        else
            return (_sl == NULL || _sl > _price) || (_tp == NULL || _tp < _price);
    };

    uint BestAskIndex(MqlBookInfo &book[])
    {
        uint booksize = ArraySize(book);
        uint i;
        for(i=0; i<booksize; i++)
            if(book[i].type == 2) break;
        return i - 1;
    };
};

class CMarketOrder : public COrder
{
public:
    CMarketOrder(string _symbol=NULL, ENUM_DESTINATION _destination=B, double _price=NULL, ulong _volume=1, double _sl=NULL, double _tp=NULL)
    {
        price = _price;
        if( !Init(_symbol, _destination, _volume, _sl, _tp) ) return;
        accepted = true;
    };

    void Execute()
    {
        MqlBookInfo book[];
        MarketBookGet(symbol, book);
        uint bai = BestAskIndex(book);
        uint bbi = bai + 1; // best bid index
        ulong init_volume = volume;
        double sum_prices = 0;
        if(destination == B)
        {
            for(uint i=bai; i>0; i--)
            {
                sum_prices += TakeBookOrder(book[i]);
                if(volume == 0) break;
            }
        }
        else // S
        {
            uint booksize = ArraySize(book);
            for(uint i=bbi; i<booksize; i++)
            {
                sum_prices += TakeBookOrder(book[i]);
                if(volume == 0) break;
            }
        }
        price = NormalizeDouble(sum_prices / init_volume, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS));
    };

protected:
    double TakeBookOrder(MqlBookInfo &book_order)
    {
        ulong vol_to_exec = book_order.volume;
        if(volume < vol_to_exec)
            vol_to_exec = volume;
        volume -= vol_to_exec;
        return book_order.price * vol_to_exec;
    };
};

class CLimitOrder : public COrder
{
protected:
    ulong  frontvolume;
    double pricestep;
public:
    CLimitOrder(string _symbol=NULL, ENUM_DESTINATION _destination=B, double _price=NULL, ulong _volume=1, double _sl=NULL, double _tp=NULL)
    {
        MqlBookInfo book[];
        MarketBookGet(symbol, book);
        pricestep = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
        if(_price == NULL)
        {
            if(destination == B) price = book[20].price;
            else if(destination == S) price = book[19].price;
        }
        else price = _price;
        if( !Init(_symbol, _destination, _volume, _sl, _tp) ) return;
        // check price step
        double x = price / pricestep;
        if((x - floor(x)) > epsilon) return;
        // check price
        if((destination == B && price > (book[19].price - epsilon)) || (destination == S && price < (book[20].price + epsilon))) return;
        // get frontvolume
        frontvolume = NULL;
        UpdateFrontvolume(book);
        accepted = true;
    };
    
    bool Modify(double new_price=NULL, double new_sl=NULL, double new_tp=NULL)
    {
        if(accepted) return false;
        if(!CheckSlTp(new_price, new_sl, new_tp)) return false;
        price = new_price;
        sl = new_sl;
        tp = new_tp;
        return true;
    };
    // return volume executed at this iteration
    ulong UpdateExecution(MqlBookInfo &book[], MqlTick &tick) override
    {
        if(tick.time_msc == last_tick_time) return 0;
        last_tick_time = tick.time_msc;
        UpdateFrontvolume(book);
        ulong executed = 0;
        if(MathAbs(tick.last - price) < epsilon)
        {
            if(frontvolume >= tick.volume)
                frontvolume -= tick.volume;
            else
            {
                ulong overfrontvol = tick.volume - frontvolume;
                frontvolume = 0;
                if(volume > overfrontvol)
                {
                    executed = overfrontvol; 
                    volume -= executed;
                }
                else
                {
                    executed = volume;
                    volume = 0;
                }
            }
        }
        return executed;
    };

protected:
    void UpdateFrontvolume(MqlBookInfo &book[])
    {
        uint booksize = ArraySize(book);
        ulong vol_at_price = 0;
        for(uint i=0; i<booksize; i++)
            if(MathAbs(price - book[i].price) < epsilon)
            {
                vol_at_price = book[i].volume;
                break;
            }
        if(frontvolume == NULL || vol_at_price < frontvolume)
            frontvolume = vol_at_price;
    };
};

class CPosition
{
protected:
    string           symbol;
    ENUM_DESTINATION destination;
    ulong            volume, volumeclosed;
    double           priceopened, priceclosed, sl, tp;
    double           sumpriceclosed;
    double           profit;
    datetime         timeopened, timeclosed;
    bool             closed;

    void UpdateProfitWithOrder(double diff, ulong book_vol, ulong &rest_vol)
    {
        ulong vol = book_vol < rest_vol ? book_vol : rest_vol;
        ENUM_SYMBOL_INFO_DOUBLE tick_profit_type = diff > 0 ? SYMBOL_TRADE_TICK_VALUE_PROFIT : SYMBOL_TRADE_TICK_VALUE_LOSS;
        profit += diff * SymbolInfoDouble(symbol, tick_profit_type) * vol;
        rest_vol -= vol;
    };

public:    
    CPosition(COrder &order)
    {
        symbol          = order.Symbol();
        destination     = order.Destination();
        volume          = 0;
        priceopened     = order.Price();
        priceclosed     = NULL;
        sumpriceclosed  = 0;
        volumeclosed    = 0;
        sl              = order.Sl();
        tp              = order.Tp();
        profit          = 0;
        timeopened      = TimeTradeServer();
        timeclosed      = NULL;
        closed          = false;
    };

    void Increase(ulong vol_to_increase, COrder &order)
    {
        if(order.Sl() != NULL)
        {
            if(order.Sl() == 0) sl = NULL;
            else sl = order.Sl();
        }
        if(order.Tp() != NULL)
        {
            if(order.Tp() == 0) tp = NULL;
            else tp = order.Tp();
        }
        priceopened = priceopened * volume + order.Price() * vol_to_increase; // sum, temp
        volume += vol_to_increase;
        priceopened /= (double)volume; // complete price adjustment 
    };

    bool Modify(double new_sl, double new_tp)
    {
        return false;
    };
    // return: decreased volume
    ulong Decrease(ulong vol_to_decrease, COrder &order)
    {
        if(volume < vol_to_decrease)
            vol_to_decrease = volume;
        sumpriceclosed += order.Price() * vol_to_decrease;
        volumeclosed += vol_to_decrease;
        volume -= vol_to_decrease;
        if(closed = volume == 0)
        {
            timeclosed = TimeTradeServer();
            priceclosed = sumpriceclosed / volumeclosed;
        }
        return vol_to_decrease;
    };

    void UpdateProfit()
    {
        profit = 0;
        MqlBookInfo book[];
        MarketBookGet(symbol, book);
        uint bai = 19; // TODO: BestAskIndex(book);
        uint bbi = bai + 1; // best bid index
        ulong rest_vol = volume;
        if(destination == B)
        {
            uint booksize = ArraySize(book);
            for(uint i=bbi; i<booksize; i++)
            {
                double diff = book[i].price - priceopened;
                UpdateProfitWithOrder(diff, book[i].volume, rest_vol);
                if(rest_vol == 0) break;
            }
        }
        else // S
        {
            for(uint i=bai; i>0; i--)
            {
                double diff = priceopened - book[i].price;
                UpdateProfitWithOrder(diff, book[i].volume, rest_vol);
                if(rest_vol == 0) break;
            }
        }
    };
    // get properties
    string           Symbol()       {return symbol;};
    double           PriceOpened()  {return priceopened;};
    double           PriceClosed()  {return priceclosed;};
    double           Sl()           {return sl;};
    double           Tp()           {return tp;};
    double           Profit()       {return profit;};
    ulong            Volume()       {return volume;};
    bool             Closed()       {return closed;};
    ENUM_DESTINATION Destination()  {return destination;};
};

class RealTimeTester
{
public: // protected:
    COrder      orders[];
    CPosition   positions[];
    string      symbol;
    uint        positions_total;
    uint        selected_pos; // index
    double      bestask, bestbid, last, spread;
    double      pricestep;
    double      fee;
    double      deposit, equity, freemargin;
    long        last_tick_time;

public:
    RealTimeTester(string _symbol=NULL, double _deposit=50000, double _fee=0)
    {
        if(symbol == NULL) symbol = _Symbol;
        fee = _fee;
        positions_total = 0;
        selected_pos = NULL;
        freemargin = equity = deposit = _deposit;
        pricestep = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
    };
    
    ~RealTimeTester()
    {
        // delete all orders and positions ?
        // save history to file
    };
    
    void Update(MqlBookInfo &book[], MqlTick &tick)
    {
        if(tick.time_msc == last_tick_time) return;
        last_tick_time = tick.time_msc;
        bestask = tick.ask;
        bestbid = tick.bid;
        last    = tick.last;
        spread  = bestask - bestbid;
        
        // Positions processing: close by sl / tp, update
        uint pos_total = ArraySize(positions);
        equity = deposit;
        for(uint i=0; i<pos_total; i++)
        {
            if(positions[i].Closed()) continue;
            if(
                (positions[i].Destination() == B &&
                ((positions[i].Tp() != NULL && positions[i].Tp() < last) || (last < positions[i].Sl() && positions[i].Sl() != NULL))) ||
                (positions[i].Destination() == S &&
                ((positions[i].Tp() != NULL && positions[i].Tp() > last) || (last > positions[i].Sl() && positions[i].Sl() != NULL)))
            )
                ClosePosition(positions[i].Symbol());
            else
            {
                positions[i].UpdateProfit();
                equity += positions[i].Profit();
            }
        }

        // Orders processing: execution
        uint orders_total = ArraySize(orders);
        for(uint i = 0; i < orders_total; i++)
        {
            ulong vol_to_open = orders[i].UpdateExecution(book, tick);
            double margin = SymbolInfoDouble(orders[i].Symbol(), SYMBOL_MARGIN_INITIAL);
            if(freemargin < margin * vol_to_open)
                vol_to_open = (ulong)floor(freemargin / margin);
            if(vol_to_open > 0)
            {
                TurnToPosition(orders[i], vol_to_open);
                if(orders[i].Volume() == 0) ArrayRemove(orders, i, 1);
            }
        }
    };

    bool BMkt(ulong volume=1, double sl=NULL, double tp=NULL)
    {
        CMarketOrder order = CMarketOrder(symbol, B, bestask, volume, sl, tp);
        return ExecuteMarket(order);
    };

    bool SMkt(ulong volume=1, double sl=NULL, double tp=NULL)
    {
        CMarketOrder order = CMarketOrder(symbol, S, bestbid, volume, sl, tp);
        return ExecuteMarket(order);
    };

    bool BLim(double price=NULL, ulong volume=1, double sl=NULL, double tp=NULL)
    {
        if(price == NULL) price = bestbid + pricestep;
        CLimitOrder order = CLimitOrder(symbol, B, price, volume, sl, tp);
        AddOrder(order);
        return order.Accepted();
    };

    bool SLim(double price=NULL, ulong volume=1, double sl=NULL, double tp=NULL)
    {
        if(price == NULL) price = bestask - pricestep;
        CLimitOrder order = CLimitOrder(symbol, S, price, volume, sl, tp);
        AddOrder(order);
        return order.Accepted();
    };

    // CancelOrder()

    void CancelBLims(string _symbol=NULL)
    {
        CancelOrdersByDestination(_symbol, B);
    };

    void CancelSLims(string _symbol=NULL)
    {
        CancelOrdersByDestination(_symbol, S);
    };

    void CancelAllOrders()
    {
        ArrayFree(orders);
    };

    bool SelectPosition(string _symbol)
    {
        if(_symbol == NULL) _symbol = _Symbol;
        int pos_total = ArraySize(positions);
        for(int i=pos_total-1; i>0; i--)
        {
            if(!positions[i].Closed() && positions[i].Symbol() == _symbol)
            {
                selected_pos = i;
                return true;
            }
        }
        return false;
    };

    void UnselectPosition()
    {
        selected_pos = NULL;
    };

    bool ClosePosition(string _symbol=NULL)
    {
        if(selected_pos != NULL) ClosePositionByIndex(selected_pos);
        if(_symbol == NULL) _symbol = _Symbol;
        int pos_total = ArraySize(positions);
        for(int i=pos_total-1; i>0; i--)
        {
            if(!positions[i].Closed() && positions[i].Symbol() == _symbol)
                return ClosePositionByIndex(i);
        }
        return false;
    };

    bool CloseAllPositions()
    {
        bool result = true;
        int pos_total = ArraySize(positions);
        for(int i=pos_total-1; i>0; i--)
        {
            if(positions[i].Closed()) continue;
            result &= ClosePosition(positions[i].Symbol());
        }
        return result;
    };
    // get selected position properties
    string PositionSymbol()
    {
        return positions[selected_pos].Symbol();
    };     
    double PositionPriceOpened()
    {
        return positions[selected_pos].PriceOpened();
    };
    double PositionPriceClosed()
    {
        return positions[selected_pos].PriceClosed();
    };
    double PositionStopLoss()
    {
        return positions[selected_pos].Sl();
    };
    double PositionTakeProfit()
    {
        return positions[selected_pos].Tp();
    };         
    double PositionProfit()     
    {
        return positions[selected_pos].Profit();
    };
    ulong PositionVolume()
    {
        return positions[selected_pos].Volume();
    };
    ENUM_DESTINATION PositionDestination()
    {
        return positions[selected_pos].Destination();
    };
    // get properties
    uint PositionsTotal()
    {
        if(positions_total == NULL)
        {
            positions_total = 0;
            uint pos_total = ArraySize(positions);
            for(uint i=0; i<pos_total; i++)
            {
                if(!positions[i].Closed())
                    positions_total++;
            }
        }
        return positions_total;
    };

protected:
    bool ExecuteMarket(CMarketOrder &order)
    {
        if(!order.Accepted()) return false;
        ulong order_vol = order.Volume();
        order.Execute();
        TurnToPosition(order, order_vol);
        return true;
    };

    bool ClosePositionByIndex(uint index)
    {
        if((int)index >= ArraySize(positions)) return false;
        if(positions[index].Closed()) return false;
        if(positions[index].Destination() == B)
            return SMkt(positions[index].Volume());
        return BMkt(positions[index].Volume()); // S
    };

    void CancelOrdersByDestination(string _symbol, ENUM_DESTINATION destination)
    {
        if(_symbol == NULL) _symbol = _Symbol;
        uint orders_total = ArraySize(orders);
        for(uint i=0; i<orders_total; i++)
        {
            if(!orders[i].Accepted()) continue;
            if(orders[i].Destination() == B && orders[i].Symbol() == _symbol)
                ArrayRemove(orders, i, 1);
        }
    };
    // Open, increase, decrease, close position with order
    void TurnToPosition(COrder &order, ulong vol_to_turn=NULL)
    {
        positions_total = NULL;
        if(vol_to_turn == NULL) vol_to_turn = order.Volume();
        if(order.position == NULL)
        {
            uint pos_total = ArraySize(positions);
            for(uint i = 0; i < pos_total; i++)
            {
                if(
                    positions[i].Closed() || 
                    (order.Symbol() != positions[i].Symbol()) ||
                    (order.Destination() == positions[i].Destination())
                ) continue;
                ulong decreased = positions[i].Decrease(vol_to_turn, order);
                vol_to_turn -= decreased;
                freemargin += decreased * SymbolInfoDouble(positions[i].Symbol(), SYMBOL_MARGIN_INITIAL);
                positions[i].UpdateProfit();
                equity -= positions[i].Profit();
                deposit += positions[i].Profit();
                if(vol_to_turn == 0) return;
                break;
            }
            for(uint i = 0; i<pos_total; i++)
            {
                if(
                    positions[i].Closed() || 
                    (order.Symbol() != positions[i].Symbol())
                ) continue;
                order.position = i;
                break;
            }
            if(order.position == NULL)
            {
                order.position = ArrayResize(positions, pos_total+1)-1;
                positions[order.position] = CPosition(order);
            }
        }
        positions[order.position].Increase(vol_to_turn, order);
        freemargin -= vol_to_turn * SymbolInfoDouble(order.Symbol(), SYMBOL_MARGIN_INITIAL);
        deposit -= fee;
        equity  -= fee;
    };

    void AddOrder(CLimitOrder &order)
    {
        if(order.Accepted())
        {
            uint index = ArrayResize(orders, ArraySize(orders)+1)-1;
            orders[index] = order;
        }
        else
            Print("Ордер не принят (шаг цены не учтён)");
    }; // Given price value doesn`t match symbol tick size +
};