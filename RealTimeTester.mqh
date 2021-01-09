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

    virtual ulong UpdateExecution(MqlBookInfo &book, MqlTick &tick) {return 0;};
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
    bool Init(string _symbol=NULL, ENUM_DESTINATION _destination, ulong _volume, double _sl=NULL, double _tp=NULL)
    {
        if(_symbol == NULL)
            symbol  = _Symbol;
        else   
            symbol  = _symbol;
        
        destination = _destination;
        volume      = _volume;
        if(!CheckSlTp(_sl, _tp)) return false;
        sl          = _sl;
        tp          = _tp;
        epsilon     = 1.0 / pow(10, SymbolInfoInteger(symbol, SYMBOL_DIGITS) + 1);
        return true;
    };
    
    bool CheckSlTp(double &_price, double &_sl, double &_tp)
    {
        if(_price == NULL) _price = price;
        if(_sl == NULL) _sl = sl;
        if(_tp == NULL) _tp = tp;
        if (destination == B)
            return (_sl == NULL || _sl < _price) || (_tp == NULL || _tp > _price);
        else
            return (_sl == NULL || _sl > _price) || (_tp == NULL || _tp < _price);
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
        if( !Init(_symbol, _destination, _volume, _sl, _tp) ) return;
        MqlBookInfo book[];
        MarketBookGet(symbol, book);
        pricestep = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
        if(_price == NULL)
        {
            if(destination == B) price = book[20].price;
            else if(destination == S) price = book[19].price;
        }
        else price = _price;
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
    ulong UpdateExecution(MqlBookInfo &book, MqlTick &tick) override
    {
        if(tick.time_msc == last_tick_time) return;
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
    void UpdateFrontvolume(MqlBookInfo &book)
    {
        int booksize = ArraySize(book);
        ulong vol_at_price = 0;
        for(int i=0; i<booksize; i++)
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
public:
    uint             index; // position index
protected:
    string           symbol;
    ENUM_DESTINATION destination;
    ulong            volume;
    double           priceopened, priceclosed, sl, tp;
    double           profit;
    datetime         timeopened, timeclosed;
    bool             closed;

public:    
    CPosition(COrder &order)
    {
        symbol      = order.symbol;
        destination = order.destination;
        volume      = 0;
        price       = order.price;
        sl          = order.sl;
        tp          = order.tp;
        index       = order.position;
        profit      = 0;
        timeopened  = TimeTradeServer();
        closed      = false;
    };

    void AddVolume(ulong vol_to_open) {volume += vol_to_open;};

    bool Modify(double new_sl, double new_tp)
    {
        return false;
    };
    // return: rest of vol_to_close;
    ulong Close(ulong vol_to_close=NULL)
    {
        ulong rest_volume = 0;
        if(vol_to_close == NULL)
            vol_to_close = volume;
        if(volume >= vol_to_close)
            volume -= vol_to_close;
        else
        {
            rest_volume = vol_to_close - volume;
            volume = 0;
        }
        if(closed = volume == 0)
            timeclosed = TimeTradeServer();
        return rest_volume;
    }
    // get properties
    string           Symbol()       {return symbol;};
    double           PriceOpened()  {return priceopened;};
    double           Sl()            {return sl;};
    double           Tp()            {return tp;};
    ulong            Volume()       {return volume;};
    bool             Closed()       {return closed;};
    ENUM_DESTINATION Destination()  {return destination;};
};

class RealTimeTester
{
public: // protected:
    COrder    orders[], orders_history[];
    CPosition positions[], positions_history[];
    string    symbol;
    int       positions_total;
    double    bestask, bestbid, spread;
    double    pricestep;
    long      last_tick_time;

public:
    RealTimeTester(string _symbol=NULL)
    {
        if(symbol == NULL) symbol = _Symbol;
        pricestep = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
    };
    
    ~RealTimeTester()
    {
        // delete all orders and positions
    }
    
    void Update(MqlBookInfo &book, MqlTick &tick)
    {
        if(tick.time_msc == last_tick_time) return;
        last_tick_time = tick.time_msc;
        bestask = tick.ask;
        bestbid = tick.bid;
        spread  = bestask - bestbid;
        
        // Positions processing: close by sl / tp

        // Orders processing: execution
        int orders_total = ArraySize(orders);
        for(uint i = 0; i < orders_total; i++)
        {
            ulong vol_to_open = orders[i].UpdateExecution(book, tick);
            if(vol_to_open > 0)
            {
                execute(orders[i], vol_to_open);
                if(orders[i].Volume() == 0) ArrayRemove(orders, i, 1);
            }
        }
    };

    bool BMkt(ulong volume=1, double sl=0, double tp=0)
    {
        if(!(sl < bestask && tp > bestask)) return false;
        CMarketOrder order = CMarketOrder(symbol, B, price, volume, sl, tp);
        execute(order);
        return true;
    };

    bool SMkt(ulong volume=1, double sl=0, double tp=0)
    {
        if(!(sl > bestbid && tp < bestbid)) return false;
        CMarketOrder order = CMarketOrder(symbol, S, price, volume, sl, tp);
        execute(order);
        return true;
    };

    bool BLim(double price=NULL, ulong volume=1, double sl=0, double tp=0)
    {
        if(price == NULL) price = bestbid + pricestep;
        if(!(sl < price && tp > price)) return false;
        CLimitOrder order = CLimitOrder(symbol, B, price, volume, sl, tp);
        AddOrder(order);
        return true;
    };

    bool SLim(double price=NULL, ulong volume=1, double sl=0, double tp=0)
    {
        if(price == NULL) price = bestask - pricestep;
        if(!(sl > price && tp < price)) return false;
        CLimitOrder order = CLimitOrder(symbol, S, price, volume, sl, tp);
        AddOrder(order);
        return true;
    };
    /*
    CPosition Netto(string _symbol)
    {
        
    };
    /**/
protected:
    void execute(COrder &order, ulong vol_to_execute=NULL)
    {
        if(vol_to_execute == NULL) vol_to_execute = order.Volume();
        if(order.position == NULL)
        {
            positions_total = ArraySize(positions);
            for(int i = 0; i < positions_total; i++)
            {
                if(
                    positions[i].Closed() || 
                    (order.Symbol() != positions[i].Symbol())
                ) continue;
                if(order.Destination() != positions[i].Destination())
                {
                    vol_to_execute = positions[i].Close(vol_to_execute);
                    if(vol_to_execute == 0) return;
                }
            }
            for(int i = 0; i < positions_total; i++)
            {
                if(
                    positions[i].Closed() || 
                    (order.Symbol() != positions[i].Symbol()) ||
                    (order.Destination() != positions[i].Destination()) ||
                    (order.Sl() != positions[i].Sl()) ||
                    (order.Tp() != positions[i].Tp())
                ) continue;
                if(MathAbs(positions[i].PriceOpened() - order.Price()) < order.Epsilon())
                {
                    order.position = i;
                    break;        
                }
            }
            if(order.position == NULL)
            {
                order.position = ArrayResize(positions, positions_total+1)-1;
                positions[order.position] = CPosition(order);
            }
        }
        positions[order.position].AddVolume(vol_to_execute);
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
    }; // Given price value doesn`t match symbol tick size
};